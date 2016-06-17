Lotto = require "hubot-reviewer-lotto"
crypto = require 'crypto'

module.exports = (robot) ->
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
    robot.messageRoom 'developers', 'pull request created.' + data
    res.status(200).send 'ok'

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