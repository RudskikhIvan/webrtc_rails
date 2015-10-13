#= require microevent
#= require_self

'use strict'

WebRTC =
  defaultOptions: {}

  attachMediaStream: (element, stream) ->
    if typeof element.srcObject != 'undefined'
      element.srcObject = stream
    else if typeof element.mozSrcObject != 'undefined'
      element.mozSrcObject = stream
    else if typeof element.src != 'undefined'
      element.src = URL.createObjectURL(stream)
    else
      throw 'Error attaching stream to element.'
    element.play()

  RTCPeerConnection: window.mozRTCPeerConnection || window.webkitRTCPeerConnection
  RTCSessionDescription: window.RTCSessionDescription || window.mozRTCSessionDescription
  RTCIceCandidate: window.RTCIceCandidate || window.mozRTCIceCandidate

  getUserMedia: (navigator.getUserMedia || navigator.mozGetUserMedia || navigator.webkitGetUserMedia).bind(navigator)

  createIceServer: (url, username, password) ->
    urlParts = url.split(':')
    return {url} if urlParts[0].indexOf('stun') == 0
    return {url, password, username} if urlParts[0].indexOf('turn') == 0
    null

  createIceServers: (urls, username, password) ->
    if navigator.webkitGetUserMedia
      return {urls: urls, credential: password, username: username}

    urls.map (url)-> WebRTC.createIceServer(url, username, password)


class WebRTC.Client extends MicroEvent

  stream: null
  partners: null

  defaultOptions:
    media:
      audio: true
      video: true

  constructor: (options)->
    @options = $.extend {}, @defaultOptions, WebRTC.defaultOptions, options
    @guid = @options.guid || @generateGuid()
    @syncEngine = @options.syncEngine || new WebRTC.SyncEngine(@, @options)
    @partners = []
    @setupLocalVideo()

  setupLocalVideo: ->
    WebRTC.getUserMedia @options.media, ((stream)=> @handleLocalStreem(stream)), ((error)=> console.log(error))

  handleLocalStreem: (stream)->
    @stream = stream
    WebRTC.attachMediaStream(@videoElement, stream) if @videoElement
    @trigger 'local_stream', stream

  getPartner: (guid)->
    @partners[guid]

  addPartner: (data)->
    @removePartner(data.guid)
    partner = new WebRTC.Partner data, client: @
    @partners[data.guid] = partner
    partner.connect()
    @trigger 'added_partner', partner
    partner

  removePartner: (guid)->
    partner = @partners[guid]
    if partner
      partner.disconnect()
      @trigger 'removed_partner', partner
      @partners[guid] = null

  connect: ->
    @syncEngine.connect()

  generateGuid: ->
    s4 = -> Math.floor((1 + Math.random()) * 0x10000).toString(16).substring(1)
    s4() + s4() + '-' + s4() + '-' + s4() + '-' + s4() + '-' + s4() + s4() + s4()

  muteAudio: -> @stream?.getAudioTracks()[0].enabled = false

  muteVideo: -> @stream?.getVideoTracks()[0].enabled = false

  unmuteAudio: -> @stream?.getAudioTracks()[0].enabled = true

  unmuteVideo: -> @stream?.getVideoTracks()[0].enabled = true

  audioMuted: -> !@stream?.getAudioTracks()[0].enabled

  videoMuted: -> !@stream?.getVideoTracks()[0].enabled


class WebRTC.SyncEngine

  constructor: (client, options)->
    @client = client
    @options = options
    @roomUrl = options.roomUrl

  initConnection: ->
    @faye = new Faye.Client(@options.url, {timeout: 220})
    @faye.subscribe @roomUrl, (data)=>
      return if data.from_guid == @client.guid
      return if data.to_guid and data.to_guid != @client.guid
      @handleSignal(data)

  connect: ->
    @initConnection()
    @sendConnect()

  sendICECandidates: (to, candidates)->
    @_sendData('candidates', candidates, to)

  sendConnect: (to = null)->
    @_sendData 'connect', {guid: @client.guid}, to

  sendOffer: (to, offer)->
    @._sendData('offer', offer, to)

  sendAnswer: (to, answer)->
    @._sendData('answer', answer, to)

  sendICECandidate: ->

  handleSignal: (signal) ->
    signal_data = JSON.parse(signal.data)

    partner = @client.getPartner(signal.from_guid)

    switch signal.signal_type
      when 'offer'
        partner ||= @client.addPartner(guid: signal.from_guid)
        partner.handleOffer signal_data
      when 'answer'
        partner.handleAnswer signal_data
      when 'candidates'
        $.each signal_data, (i, candidate) ->
          partner.handleRemoteICECandidate candidate
      when 'connect'
        partner = @client.addPartner(signal_data)
        partner.sendOffer({})
      when 'disconnect'
        @client.removePartner(signal.from_guid)
      else
        console.log 'warning', 'Unknown signal type "' + signal.signal_type + '" received.', signal
        break

  _sendData: (signal, data, to = null)->
    @faye.publish(@roomUrl, {from_guid: @client.guid, to_guid: to, signal_type: signal, data: JSON.stringify(data)})


class WebRTC.Partner
  stream: null
  connection: null
  guid: null
  client: null

  constructor: (data, options)->
    @guid = data.guid
    @client = options.client
    @syncEngine = @client.syncEngine
    @options = options

    @localICECandidates = []

    @client.trigger 'partner.created'

  muteAudio: -> @stream?.getAudioTracks()[0].enabled = false

  muteVideo: -> @stream?.getVideoTracks()[0].enabled = false

  unmuteAudio: -> @stream?.getAudioTracks()[0].enabled = true

  unmuteVideo: -> @stream?.getVideoTracks()[0].enabled = true

  audioMuted: -> !@stream?.getAudioTracks()[0].enabled

  videoMuted: -> !@stream?.getVideoTracks()[0].enabled

  connect: ->
    configuration = iceServers: @client.options.iceServers
    @connection = new WebRTC.RTCPeerConnection(configuration)
    @connection.addStream @client.stream
    @connection.onicecandidate = @handleLocalICECandidate.bind(@)
    @connection.onaddstream = (event)=> @handleRemoteStream(event.stream)


  sendOffer: (options) ->
    @connection.createOffer ((offer) =>
      @connection.setLocalDescription offer
      @syncEngine.sendOffer @guid, offer
      #setTimeout self._checkForConnection, self._options.connectionTimeout
    ), ->


  handleOffer: (offer) ->
    offer = new WebRTC.RTCSessionDescription(offer)
    @connection.setRemoteDescription offer
    @connection.createAnswer ((answer) =>
      @connection.setLocalDescription new WebRTC.RTCSessionDescription(answer)
      @syncEngine.sendAnswer @guid, answer
    ), ->

  handleAnswer: (answer) ->
    @connection.setRemoteDescription new WebRTC.RTCSessionDescription(answer)

  handleRemoteICECandidate: (candidate) ->
    candidate = new WebRTC.RTCIceCandidate(candidate)
    @connection.addIceCandidate candidate

  handleLocalICECandidate: (event)->
    candidate = event.candidate
    if candidate
      @localICECandidates.push event.candidate
      @syncEngine.sendICECandidate @guid, event.candidate
    else
      @syncEngine.sendICECandidates @guid, @localICECandidates

  handleRemoteStream: (stream)->
    @connected = true
    @stream = stream
    @client.trigger 'partner.stream', @

  disconnect: ->
    try
      @connection.close()
    catch ex
    #TODO: send signal
    @client.trigger 'partner.disconnect', @

if typeof module != 'undefined'
  module.exports =
    WebRTC: WebRTC
else
  window.WebRTC = WebRTC
