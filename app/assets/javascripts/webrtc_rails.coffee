#= require adapter-latest
#= require microevent
#= require_self

'use strict'

CAPTURE_EVENT_FRONTEND = 'screen_capture_frontend'
CAPTURE_EVENT_BACKEND = 'screen_capture_backend'
PLUGIN_VERSION_NEEDED = '1.3.0'
CHECK_VERSION_TIMEOUT = 2000
TRY_COUNT_LIMIT = 3
PARTNER_CONNECTION_TIMEOUT = 10000

screenshot_id = 0
screenshot_callbacks = {} 


window.addEventListener 'message', (event)->
  return if event.data.target != CAPTURE_EVENT_FRONTEND
  return if event.data.type != 'screenshot'
  WebRTC.onScreenShot(event.data.data)

WebRTC =
  defaultOptions: {}
  debug: false

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

  RTCPeerConnection: window.RTCPeerConnection
  RTCSessionDescription: window.RTCSessionDescription
  RTCIceCandidate: window.RTCIceCandidate

  getUserMedia: navigator.getUserMedia.bind(navigator)

  log: ->
    return unless WebRTC.debug
    console.log.apply(console, arguments)


  makeScreenshot: (options, callback)->
    if options instanceof Function
      callback = options
      options = {}
    screenshot_id += 1
    options['screenshot_id'] = screenshot_id
    screenshot_callbacks[screenshot_id] = callback
    window.postMessage({target: CAPTURE_EVENT_BACKEND, type: 'make_screenshot', data: options}, '*')

  onScreenShot: (data)->
    screenshot_id = data.screenshot_id
    if screenshot_callbacks[screenshot_id]
      screenshot_callbacks[screenshot_id](data.image)


class WebRTC.Client extends MicroEvent

  stream: null
  capturedStream: null
  partners: null
  pluginConnection: null
  pluginStream: null
  pluginVersion: null

  defaultOptions:
    media:
      audio: true
      video: true
    offer:
      offerToReceiveAudio: 1,
      offerToReceiveVideo: 1,
      iceRestart: true

  constructor: (options)->
    @options = $.extend {}, @defaultOptions, WebRTC.defaultOptions, options
    @guid = @options.guid || @generateGuid()
    @syncEngine = @options.syncEngine || new WebRTC.SyncEngine(@, @options)
    @stream = @options.stream
    WebRTC.debug = true if @options.debug
    @partners = {}
    @setupLocalVideo()
    @initCapturingPluginEvents()
    @checkPluginVersion() if @options.capturingRequired
    if WebRTC.debug
      WebRTC.clients ||= {}
      WebRTC.clients[@guid] = @


  setupLocalVideo: ->
    WebRTC.getUserMedia @options.media, ((stream)=> @handleLocalStream(stream)), (error)=>
      @trigger 'user_media_error', error
      WebRTC.log error

  handleLocalStream: (stream)->
    @stream ||= stream
    WebRTC.attachMediaStream(@videoElement, stream) if @videoElement
    @trigger 'local_stream', stream
    @connect()

  getPartner: (guid)->
    @partners[guid]

  addPartner: (data, incoming = false)->
    @removePartner(data.guid)
    partner = new WebRTC.Partner data, client: @
    @partners[data.guid] = partner
    partner.connect()
    @trigger 'added_partner', partner
    @waitConnectionFor(data.guid) if incoming
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
      return if event.data.target != CAPTURE_EVENT_FRONTEND
      @onPluginEvent(event.data.type, event.data.data)

  startScreenCapture: ->
    window.postMessage({target: CAPTURE_EVENT_BACKEND, type: 'start_capture', data: @capturingParams()}, '*')

  stopScreenCapture: ->
    window.postMessage({target: CAPTURE_EVENT_BACKEND, type: 'stop_capture', data: {}}, '*')

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
    conn = new WebRTC.RTCPeerConnection(iceServers: [])
    conn.addEventListener 'addstream', (event)=> @handlePluginStream(event.stream)
    conn.addEventListener 'icecandidate', (event)=> @sendCapturingEngineEvent('remote_candidate', event.candidate) if event.candidate
    conn.setRemoteDescription(new WebRTC.RTCSessionDescription(offer))
    conn.createAnswer().then((answer)=>
      conn.setLocalDescription(new WebRTC.RTCSessionDescription(answer))
      @sendCapturingEngineEvent('handle_answer', answer)
    ).catch (error)=> console.error('createPluginAnswerError', e)
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
      when 'version' then @onPluginVersionReceived(data)

  sendCapturingEngineEvent: (event_name, data)->
    window.postMessage({target: CAPTURE_EVENT_BACKEND, type: event_name, data: JSON.parse(JSON.stringify(data))}, '*')

  checkPluginVersion: ->
    @sendCapturingEngineEvent('version', null)
    setTimeout @onPluginVersionReceived.bind(@), CHECK_VERSION_TIMEOUT

  onPluginVersionReceived: (version)->
    return if @pluginVersion
    @pluginVersion = version if version
    if @pluginVersion
      if @versionToInt( @pluginVersion ) < @versionToInt( PLUGIN_VERSION_NEEDED )
        @trigger 'plugin_version_not_match', @pluginVersion
      else
        @trigger 'plugin_version', @pluginVersion
    else
      @trigger 'plugin_not_exists'

  versionToInt: (version)->
    vs = version.split('.')
    vs[0] * 100 + (vs[1] || 0) * 10 + (vs[2] || 0)

  partnerConnected: (guid)->
    partner = @getPartner(guid)
    return false if !partner
    iceState = partner.connection.iceConnectionState
    iceState == 'completed' or iceState == 'connected'

  waitConnectionFor: (guid)->
    check = =>
      partner = @getPartner(guid)
      if partner and !@partnerConnected(guid)
        partner.tryReconnect()

    setTimeout check, PARTNER_CONNECTION_TIMEOUT


sendedSignals = {}
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

  sendICECandidate: (to, candidate)->
    @_sendData('candidate', candidate, to)

  sendICECandidates: (to, candidates)->
    @_sendData('candidates', candidates, to)

  sendConnect: (to = null)->
    @_sendData 'connect', {guid: @client.guid}, to

  sendOffer: (to, offer)->
    @_sendData('offer', offer, to)

  sendAnswer: (to, answer)->
    @_sendData('answer', answer, to)

  sendReconnect: (to)->
    @_sendData 'reconnect', {guid: @client.guid}, to

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

  handleSignal: (signal) ->
    signal_data = JSON.parse(signal.data)
    partner = @client.getPartner(signal.from_guid)
    WebRTC.log("Signal [#{signal.signal_type}] received: ", signal_data)

    switch signal.signal_type
      when 'offer'
        partner ||= @client.addPartner(guid: signal.from_guid)
        partner.handleOffer signal_data
      when 'answer'
        partner.handleAnswer signal_data if partner
      when 'candidates'
        partner.handleRemoteICECandidates signal_data if partner
      when 'candidate'
        partner.handleRemoteICECandidate signal_data if partner
      when 'connect'
        partner = @client.addPartner(signal_data, true)
        partner.sendOffer()
      when 'reconnect'
        partner = @client.addPartner(signal_data)
        partner.sendOffer()
      when 'disconnect'
        @client.removePartner(signal.from_guid)
      when 'captured.offer'
        partner.capturingConnection.handleOffer signal_data if partner
      when 'captured.answer'
        partner.capturingConnection.handleAnswer signal_data if partner
      when 'captured.stop'
        partner.stopScreenCapturing() if partner
      when 'captured.candidates'
        for candidate in signal_data
          partner.capturingConnection.handleRemoteICECandidates candidate if partner
      when 'captured.candidate'
        partner.capturingConnection.handleRemoteICECandidate signal_data if partner
      else
        WebRTC.log 'warning', 'Unknown signal type "' + signal.signal_type + '" received.', signal
        break

  _sendData: (signal, data, to = null, options = {})->
    output = {from_guid: @client.guid, to_guid: to, signal_type: signal, data: JSON.stringify(data)}
    WebRTC.log("Signal [#{signal}] sended", output)
    @faye.publish(@roomUrl, output)

  _timestamp: ->
    new Date().getTime()


class WebRTC.Partner
  stream: null
  connection: null
  guid: null
  client: null
  source: false
  receivedSignals: null
  localICECandidatesComplete: false

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
    @disconnect() if @connection
    @localICECandidates = []
    @localICECandidatesComplete = false
    @receivedSignals = {}
    configuration =
      rtcpMuxPolicy: "require"
      bundlePolicy: "max-bundle"
      iceServers: @client.options.iceServers || []
    @connection = new WebRTC.RTCPeerConnection(configuration)
    @connection.addStream @client.stream
    @connection.addEventListener 'icecandidate', @handleLocalICECandidate.bind(@)
    @connection.addEventListener 'addstream', (event)=> @onRemoteStreamAdded(event.stream)
    @connection.addEventListener 'removestream', @onRemoteStreamRemoved.bind(@)

  sendOffer: ->
    @source = true
    @connection.createOffer(@client.options.offer).then((offer) =>
      @connection.setLocalDescription offer
      @syncEngine.sendOffer @guid, offer
    ).catch (error)-> console.error('creationOfferError', error)

  handleOffer: (offer) ->
    @source = false
    return if @receivedSignals['offer']
    @receivedSignals['offer'] = offer
    offer = new WebRTC.RTCSessionDescription(offer)
    @connection.setRemoteDescription offer
    @connection.createAnswer().then((answer) =>
      @connection.setLocalDescription new WebRTC.RTCSessionDescription(answer)
      @syncEngine.sendAnswer @guid, answer
    ).catch (error)-> console.error('creationAnswerError', error)

  handleAnswer: (answer) ->
    return if @receivedSignals['answer']
    @receivedSignals['answer'] = answer
    @connection.setRemoteDescription new WebRTC.RTCSessionDescription(answer)
    @sendLocalICECandidates()

  handleRemoteICECandidate: (candidate) ->
    candidate = new WebRTC.RTCIceCandidate(candidate)
    @connection.addIceCandidate candidate

  handleRemoteICECandidates: (candidates) ->
    @receivedSignals['candidates'] = candidates
    for candidate in candidates
      candidate = new WebRTC.RTCIceCandidate(candidate)
      @connection.addIceCandidate candidate

  handleLocalICECandidate: (event)->
    candidate = event.candidate
    if candidate
      @localICECandidates.push event.candidate
      @syncEngine.sendICECandidate @guid, event.candidate
    else
      @localICECandidatesComplete = true
      @sendLocalICECandidates()

  sendLocalICECandidates: ->
    return unless @localICECandidates
    return unless @localICECandidatesComplete
    return if @source and !@receivedSignals['answer']
    @syncEngine.sendICECandidates @guid, @localICECandidates
    @localICECandidates = null
    @localICECandidatesComplete = false

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
    try @connection.close() catch ex
    @connected = false
    @connection = null
    @client.trigger 'partner.disconnect', @
    try @stopScreenCapturing() catch ex

  tryReconnect: ->
    @connect()
    @syncEngine.sendReconnect @guid


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
    @closeConnection()
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
    @connection.createAnswer().then((answer) =>
      @connection.setLocalDescription(new WebRTC.RTCSessionDescription(answer))
      @syncEngine.sendCapturedAnswer @guid, answer
    ).catch (error)-> console.error('creationCapturingAnswerError', error)

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
    @connection.createOffer(@client.options.offer).then( (offer)=>
      @connection.setLocalDescription(new WebRTC.RTCSessionDescription(offer))
      @syncEngine.sendCapturedOffer @guid, offer
    ).catch (error)-> console.error('creationCapturingOfferError', error)

  disconnect: ->
    @closeConnection()
    @stream = null
    if @source
      @syncEngine.sendCapturedStop(@guid)
    else
      @client.trigger 'partner.captured_stream_removed', @

  closeConnection: ->
    try
      @connection.close() if @connection
      @connection = null
    catch ex

if typeof module != 'undefined'
  module.exports =
    WebRTC: WebRTC
else
  window.WebRTC = WebRTC
