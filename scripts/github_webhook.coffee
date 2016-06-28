# Description:
#   assigns random reviewer for a pull request (for webhook).
#
# Configuration:
#   HUBOT_GITHUB_TOKEN (required)
#   HUBOT_GITHUB_ORG (required)
#   HUBOT_GITHUB_REVIEWER_TEAM (required)
#     github team id. this script randomly picks a reviewer from this team members.
#
# Commands:
#   hubot reviewer for <repo> <pull> - assigns random reviewer for pull request
#   hubot reviewer show stats - proves the lotto has no bias
#
# Author:
#   sakatam

_         = require "underscore"
async     = require "async"
GitHubApi = require "github"
weighted  = require "weighted"
crypto    = require 'crypto'

s_to_a = (s) ->
  console.log(s)
  if s == undefined
    return []

  a =s.split(',').map((e) ->
    return e.trim()
  )

  if a.length == 1 && a[0] == ''
    return []

  return a

module.exports = (robot) ->
  ghToken       = process.env.HUBOT_GITHUB_TOKEN
  ghOrg         = process.env.HUBOT_GITHUB_ORG
  ghReviwerTeam = process.env.HUBOT_GITHUB_REVIEWER_TEAM
  ghWithAvatar  = process.env.HUBOT_GITHUB_WITH_AVATAR in ["1", "true"]
  normalMessage = process.env.HUBOT_REVIEWER_LOTTO_MESSAGE || "Please review this."
  politeMessage = process.env.HUBOT_REVIEWER_LOTTO_POLITE_MESSAGE || "#{normalMessage} :bow::bow::bow::bow:"
  debug         = process.env.HUBOT_REVIEWER_LOTTO_DEBUG in ["1", "true"]
  labels        = s_to_a(process.env.HUBOT_REVIEWER_LOTTO_LABELS)
  slack_team    = process.env.HUBOT_SLACK_TEAM
  STATS_KEY     = 'reviewer-lotto-stats'

  # draw lotto - weighted random selection
  draw = (reviewers, stats = null) ->
    max = if stats? then (_.max _.map stats, (count) -> count) else 0
    arms = {}
    sum = 0
    for {login} in reviewers
      weight = Math.exp max - (stats?[login] || 0)
      arms[login] = weight
      sum += weight
    # normalize weights
    for login, weight of arms
      arms[login] = if sum > 0 then weight / sum else 1
    if debug
      robot.logger.info 'arms: ', arms

    selected = weighted.select arms
    _.find reviewers, ({login}) -> login == selected

  if !ghToken? or !ghOrg? or !ghReviwerTeam?
    return robot.logger.error """
      reviewer-lottery is not loaded due to missing configuration!
      #{__filename}
      HUBOT_GITHUB_TOKEN: #{ghToken}
      HUBOT_GITHUB_ORG: #{ghOrg}
      HUBOT_GITHUB_REVIEWER_TEAM: #{ghReviwerTeam}
    """

  reviewer_lotto = (robot, response, prParams) ->
    gh = new GitHubApi version: "3.0.0"
    gh.authenticate {type: "oauth", token: ghToken}

    # mock api if debug mode
    if debug
      gh.issues.createComment = (params, cb) ->
        robot.logger.info "GitHubApi - createComment is called", params
        cb null
      gh.issues.edit = (params, cb) ->
        robot.logger.info "GitHubApi - edit is called", params
        cb null

    async.waterfall [
      (cb) ->
        # get team members
        params =
          id: ghReviwerTeam
          per_page: 100
        gh.orgs.getTeamMembers params, (err, res) ->
          return cb "error on getting team members: #{err.toString()}" if err?
          cb null, {reviewers: res}

      (ctx, cb) ->
        robot.messageRoom slack_team, "looking for the pr...\n#{prParams.user}, #{prParams.repo}, #{prParams.number}"
        # check if pull req exists
        gh.pullRequests.get prParams, (err, res) ->
          return cb "error on getting pull request: #{err.toString()}" if err?
          ctx['issue'] = res
          ctx['creator'] = res.user
          ctx['assignee'] = res.assignee
          cb null, ctx

      (ctx, cb) ->
        # pick reviewer
        {reviewers, creator, assignee} = ctx
        reviewers = reviewers.filter (r) -> r.login != creator.login
        # exclude current assignee from reviewer candidates
        if assignee?
          reviewers = reviewers.filter (r) -> r.login != assignee.login

        ctx['reviewer'] = draw reviewers, robot.brain.get(STATS_KEY)
        cb null, ctx

      (ctx, cb) ->
        # post a comment
        {reviewer} = ctx
        body = "@#{reviewer.login} " + if prParams.polite then politeMessage else normalMessage
        params = _.extend { body }, prParams
        gh.issues.createComment params, (err, res) -> cb err, ctx

      (ctx, cb) ->
        # change assignee
        {reviewer} = ctx
        params = _.extend { assignee: reviewer.login }, prParams
        gh.issues.edit params, (err, res) -> cb err, ctx

      (ctx, cb) ->
        {reviewer, issue} = ctx
        robot.messageRoom slack_team, "#{reviewer.login} さん、レビュアーにご指名ですー PR: #{issue.html_url}"
        if ghWithAvatar
          url = reviewer.avatar_url
          url = "#{url}t=#{Date.now()}" # cache buster
          url = url.replace(/(#.*|$)/, '#.png') # hipchat needs image-ish url to display inline image
          response.send url

        # update stats
        stats = (robot.brain.get STATS_KEY) or {}
        stats[reviewer.login] or= 0
        stats[reviewer.login]++
        robot.brain.set STATS_KEY, stats

        cb null, ctx

    ], (err, res) ->
      if err?
        robot.messageRoom slack_team, "an error occured.\n#{err}"
        return response.send "error"
    return response.send "success"

  robot.respond /reviewer reset stats/i, (msg) ->
    robot.brain.set STATS_KEY, {}
    msg.reply "Reset reviewer stats!"

  robot.respond /reviewer show stats$/i, (msg) ->
    stats = robot.brain.get STATS_KEY
    msgs = ["login, percentage, num assigned"]
    total = 0
    for login, count of stats
      total += count
    for login, count of stats
      percentage = Math.floor(count * 100.0 / total)
      msgs.push "#{login}, #{percentage}%, #{count}"
    msg.reply msgs.join "\n"

  robot.respond /reviewer for ([\w-\.]+) (\d+)( polite)?$/i, (msg) ->
    repo = msg.match[1]
    pr   = msg.match[2]
    polite = msg.match[3]?
    params =
      user: ghOrg
      repo: repo
      number: pr
      polite: polite

    return reviewer_lotto robot, msg, params

  robot.router.post "/github/webhook", (req, res) ->
    event_type = req.get 'X-Github-Event'
    signature = req.get 'X-Hub-Signature'

    # unless isCorrectSignature signature, req.body
    #   res.status(401).send 'unauthorized'
    #   return

    if event_type != 'pull_request'
      res.status(404).send 'not found' + event_type
      return

    data = req.body
    if data.action != 'labeled'
      return res.send "labeled event is only acceptable. #{data.action}"

    if data.label == undefined
      return res.send "label is not defined."

    label = data.label.name
    if labels.length != 0 and labels.indexOf(label) == -1
      return res.send "label is not matched. #{labels}, #{label}"

    repo = data.repository.name
    pr   = data.pull_request.number
    polite = false
    prParams =
      user: ghOrg
      repo: repo
      number: pr

    return reviewer_lotto robot, res, prParams

  isCorrectSignature = (signature, body) ->
    if signature == undefined
      return false

    pairs = signature.split '='
    digest_method = pairs[0]
    hmac = crypto.createHmac digest_method, process.env.HUBOT_GITHUB_SECRET
    hmac.update JSON.stringify(body), 'utf-8'
    hashed_data = hmac.digest 'hex'
    generated_signature = [digest_method, hashed_data].join '='
    return signature is generated_signature