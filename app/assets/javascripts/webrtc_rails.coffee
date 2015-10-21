#= require microevent
#= require_self

'use strict'

capture_event_frontend = 'screen_capture_frontend'
capture_event_backend = 'screen_capture_backend'


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
  capturedStream: null
  partners: null
  pluginConnection: null
  pluginStream: null

  defaultOptions:
    media:
      audio: true
      video: true

  constructor: (options)->
    @options = $.extend {}, @defaultOptions, WebRTC.defaultOptions, options
    @guid = @options.guid || @generateGuid()
    @syncEngine = @options.syncEngine || new WebRTC.SyncEngine(@, @options)
    @stream = @options.stream
    @partners = {}
    @setupLocalVideo()
    @initCapturingPluginEvents()

  setupLocalVideo: ->
    WebRTC.getUserMedia @options.media, ((stream)=> @handleLocalStreem(stream)), ((error)=> console.log(error))

  handleLocalStreem: (stream)->
    @stream ||= stream
    WebRTC.attachMediaStream(@videoElement, stream) if @videoElement
    @trigger 'local_stream', stream
    @connect()

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

  initCapturingPluginEvents: ->
    window.addEventListener 'message', (event)=>
      return if event.data.target != capture_event_frontend
      @onPluginEvent(event.data.type, event.data.data)

  startScreenCapture: ->
    window.postMessage({target: capture_event_backend, type: 'start_capture', data: @capturingParams()}, '*')

  stopScreenCapture: ->
    window.postMessage({target: capture_event_backend, type: 'stop_capture', data: {}}, '*')

  onCapturingStreamEnded: ->
    @trigger 'plugin_stream_ended'
    $.each @partners, (k,partner)->
      partner.stopScreenCapturing()

  capturingParams: ->
    partners: $.map(@partners, (o)-> o.guid )
    iceServers: @options.iceServers

  generateGuid: ->
    s4 = -> Math.floor((1 + Math.random()) * 0x10000).toString(16).substring(1)
    s4() + s4() + '-' + s4() + '-' + s4() + '-' + s4() + '-' + s4() + s4() + s4()

  muteAudio: -> @stream?.getAudioTracks()[0].enabled = false

  muteVideo: -> @stream?.getVideoTracks()[0].enabled = false

  unmuteAudio: -> @stream?.getAudioTracks()[0].enabled = true

  unmuteVideo: -> @stream?.getVideoTracks()[0].enabled = true

  audioMuted: -> !@stream?.getAudioTracks()[0].enabled

  videoMuted: -> !@stream?.getVideoTracks()[0].enabled

  hanglePluginOffer: (offer)->
    conn = new WebRTC.RTCPeerConnection(iceServers: @options.iceServers)
    conn.addEventListener 'addstream', (event)=> @handlePluginStream(event.stream)
    conn.addEventListener 'icecandidate', (event)=> @sendCapturingEngineEvent('remote_candidate', event.candidate) if event.candidate
    conn.setRemoteDescription(new WebRTC.RTCSessionDescription(offer))
    conn.createAnswer (answer)=>
      conn.setLocalDescription(new WebRTC.RTCSessionDescription(answer))
      @sendCapturingEngineEvent('handle_answer', answer)
    @pluginConnection = conn

  hanglePluginICECandidate: (candidate)->
    @pluginConnection.addIceCandidate(new WebRTC.RTCIceCandidate(candidate))

  handlePluginStream: (stream)->
    @pluginStream = stream
    @trigger 'plugin_stream', @pluginStream
    @sendCapturedStreamToPartners()

  sendCapturedStreamToPartners: ->
    $.each @partners, (_, partner)=>
      partner.capturingConnection.sendCapturedStream(@pluginStream)

  onPluginEvent: (event, data)->
    switch event
      when 'send_offer' then @hanglePluginOffer(data)
      when 'send_candidate' then @hanglePluginICECandidate(data)
      when 'stream_ended' then @onCapturingStreamEnded()

  sendCapturingEngineEvent: (event_name, data)->
    window.postMessage({target: capture_event_backend, type: event_name, data: JSON.parse(JSON.stringify(data))}, '*')


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
    @_sendData('offer', offer, to)

  sendAnswer: (to, answer)->
    @_sendData('answer', answer, to)

  sendCapturedOffer: (to, offer)->
    @_sendData('captured.offer', offer, to)

  sendCapturedICECandidates: (to, candidates)->
    #@_sendData('captured.candidates', candidates, to)

  sendCapturedICECandidate: (to, candidate)->
    @_sendData('captured.candidate', candidate, to)

  sendCapturedOffer: (to, offer)->
    @_sendData('captured.offer', offer, to)

  sendCapturedAnswer: (to, answer)->
    @_sendData('captured.answer', answer, to)

  sendCapturedStop: (to)->
    @_sendData('captured.stop', {}, to)

  sendICECandidate: (to, candidate)->
    @_sendData('candidate', candidate, to)

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
      when 'candidate'
        partner.handleRemoteICECandidate signal_data
      when 'connect'
        partner = @client.addPartner(signal_data)
        partner.sendOffer({})
      when 'disconnect'
        @client.removePartner(signal.from_guid)
      when 'captured.offer'
        partner.capturingConnection.handleOffer signal_data
      when 'captured.answer'
        partner.capturingConnection.handleAnswer signal_data
      when 'captured.stop'
        partner.stopScreenCapturing()
      when 'captured.candidates'
        $.each signal_data, (i, candidate) ->
          partner.capturingConnection.handleRemoteICECandidate candidate
      when 'captured.candidate'
        partner.capturingConnection.handleRemoteICECandidate signal_data
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
    @capturingConnection = new WebRTC.CapturingConnection(@)

    @client.trigger 'partner.created', @

  muteAudio: -> @stream?.getAudioTracks()[0].enabled = false

  muteVideo: -> @stream?.getVideoTracks()[0].enabled = false

  unmuteAudio: -> @stream?.getAudioTracks()[0].enabled = true

  unmuteVideo: -> @stream?.getVideoTracks()[0].enabled = true

  audioMuted: -> !@stream?.getAudioTracks()[0].enabled

  videoMuted: -> !@stream?.getVideoTracks()[0].enabled

  connect: ->
    @localICECandidates = []
    configuration = iceServers: @client.options.iceServers
    @connection = new WebRTC.RTCPeerConnection(configuration)
    @connection.addStream @client.stream
    @connection.addEventListener 'icecandidate', @handleLocalICECandidate.bind(@)
    @connection.addEventListener 'addstream', (event)=> @onRemoteStreamAdded(event.stream)
    @connection.addEventListener 'removestream', @onRemoteStreamRemoved.bind(@)

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

  onRemoteStreamAdded: (stream)->
    @connected = true
    @stream = stream
    @client.trigger 'partner.stream_added', @

  onRemoteStreamRemoved: ->
    @connected = false
    @stream = null
    @client.trigger 'partner.stream_removed'

  stopScreenCapturing: ->
    @capturingConnection.disconnect()

  disconnect: ->
    try
      @connection.close()
    catch ex
    @connected = false
    #TODO: send signal
    @client.trigger 'partner.disconnect', @

class WebRTC.CapturingConnection
  guid: null
  partner: null
  stream: null
  pluginConnection: null
  connection: null
  source: false

  constructor: (partner)->
    @guid = partner.guid
    @client = partner.client || partner
    @syncEngine = @client.syncEngine
    @client.trigger 'partner.capturing_created', @

  connect: (stream)->
    @connection.close() if @connection
    if stream
      @source = true
      @stream = stream
    else
      @source = false

    @localICECandidates = []
    configuration = iceServers: @client.options.iceServers
    @connection = new WebRTC.RTCPeerConnection(configuration)
    @connection.addStream(@stream) if @stream
    @connection.addEventListener 'icecandidate', @handleLocalICECandidate.bind(@)
    @connection.addEventListener 'addstream', (event)=> @onRemoteStreamAdded(event.stream)
    @connection.addEventListener 'removestream', @onRemoteStreamRemoved.bind(@)

  handleLocalICECandidate: (event)->
    candidate = event.candidate
    if candidate
      @localICECandidates.push candidate
      @syncEngine.sendCapturedICECandidate @guid, candidate
    else
      @syncEngine.sendCapturedICECandidates @guid, @localICECandidates

  handleOffer: (offer)->
    @connect()
    @connection.setRemoteDescription(new WebRTC.RTCSessionDescription(offer))
    @connection.createAnswer ((answer) =>
      @connection.setLocalDescription(new WebRTC.RTCSessionDescription(answer))
      @syncEngine.sendCapturedAnswer @guid, answer
    ), ->

  handleRemoteICECandidate: (candidate)->
    @connection.addIceCandidate(new WebRTC.RTCIceCandidate(candidate))

  handleAnswer: (answer)->
    @connection.setRemoteDescription(new WebRTC.RTCSessionDescription(answer))

  onRemoteStreamAdded: (stream)->
    return if @source
    @stream = stream
    @client.trigger 'partner.captured_stream_added', @

  onRemoteStreamRemoved: ->
    @stream = null

  sendCapturedStream: (stream)->
    @connect(stream)
    @connection.createOffer (offer)=>
      @connection.setLocalDescription(new WebRTC.RTCSessionDescription(offer))
      @syncEngine.sendCapturedOffer @guid, offer

  disconnect: ->
    @connection.close() if @connection
    @connection = null
    @stream = null
    if @source
      @syncEngine.sendCapturedStop(@guid)
    else
      @client.trigger 'partner.captured_stream_removed', @

if typeof module != 'undefined'
  module.exports =
    WebRTC: WebRTC
else
  window.WebRTC = WebRTC
