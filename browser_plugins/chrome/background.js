var localStream = null;
var captureParams = null;
var partners = {};
var pearConnection = null;
var localICECandidates = null;

chrome.extension.onMessage.addListener(function(request){
  if (request && request.type) onEvent(request.type, request.data);
});

function sendEvent(type, data) {
  //console.log('Send Event', type, data);
  chrome.windows.getCurrent(function(window){
    chrome.tabs.query({active: true, windowId: window.id}, function(tabs){
      chrome.tabs.sendMessage(tabs[0].id, {type: type, data: data});
    });
  });
}

function onEvent(type, data) {
  //console.log('Get Event', type, data);
  switch (type) {
    case 'start_capture' : startCapture(data); break;
    case 'stop_capture' : stopCapture(data); break;
    case 'handle_answer' : handleAnswer(data); break;
    case 'remote_candidate' : handleRemoteICECandidate(data); break;
  }
}

function startCapture(params) {
  stopCapture();
  captureParams = params;
  chrome.desktopCapture.chooseDesktopMedia(["screen", "window"], onAccessApproved);
}

function stopCapture() {
  if (localStream) localStream.stop();
  localStream = null;
}

function captureOptions(desktop_id) {
  return {
    audio: false,
    video: {
      mandatory: {
        chromeMediaSource: 'desktop',
        chromeMediaSourceId: desktop_id,
        //minWidth: captureParams.minWidth || 1280,
        maxWidth: captureParams.maxWidth || 1280,
        //minHeight: captureParams.minHeight || 720,
        maxHeight: captureParams.maxHeight || 720
      }
    }
  }
}

function onAccessApproved(desktop_id) {
  if (!desktop_id) { return; }
  desktopSharing = true;

  navigator.webkitGetUserMedia(captureOptions(desktop_id), gotStream, getUserMediaError);

  function gotStream(stream) {
    localStream = stream;
    createConnection(stream);
  }

  function getUserMediaError(e) {
    console.log('getUserMediaError: ' + JSON.stringify(e, null, '---'));
  }
}

function createConnection(stream) {
  if (pearConnection) pearConnection.close();
  stream.addEventListener('ended', onStreamEnded);
  localICECandidates = [];
  pearConnection = new webkitRTCPeerConnection({iceServers: captureParams.iceServers});
  pearConnection.addStream(stream);
  pearConnection.addEventListener('icecandidate', handleLocalICECandidate.bind(this));
  pearConnection.createOffer(function(offer){
    pearConnection.setLocalDescription(new RTCSessionDescription(offer));
    sendEvent('send_offer', offer);
  });
}

function onStreamEnded(){
  sendEvent('stream_ended');
}

function handleAnswer(answer) {
  pearConnection.setRemoteDescription(new RTCSessionDescription(answer));
}

function handleLocalICECandidate(event) {
  candidate = event.candidate
  if (candidate) {
    localICECandidates.push(candidate);
    sendEvent('send_candidate', candidate);
  }
  else {
    sendEvent('send_candidates', this.localICECandidates);
  }
}

function handleRemoteICECandidate (candidate) {
  pearConnection.addIceCandidate(new RTCIceCandidate(candidate))
}

function disconnect() {
  if ( pearConnection ) {
    pearConnection.removeStream(localStream);
    pearConnection = null;
    pearConnection.close();
  }
}
