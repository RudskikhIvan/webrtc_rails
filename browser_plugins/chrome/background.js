var localStream = null;
var captureParams = null;
var partners = {};
var pearConnection = null;
var VERSION = '1.2.0';

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
    case 'make_screenshot' : makeScreenshot(data); break;
    case 'version' : sendEvent('version', VERSION)
  }
}

function startCapture(params) {
  stopCapture();
  captureParams = params;
  chrome.desktopCapture.chooseDesktopMedia(["screen", "window"], onAccessApproved);
}

function stopCapture() {
  if ( !localStream ) return;
  var track = localStream.getTracks()[0];
  if ( track ) track.stop();
  localStream.active = false;
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
  if (pearConnection) disconnect();
  stream.addEventListener('ended', onStreamEnded);
  localICECandidates = [];
  pearConnection = new webkitRTCPeerConnection({iceServers: []});
  pearConnection.addStream(stream);
  pearConnection.addEventListener('icecandidate', handleLocalICECandidate.bind(this));
  pearConnection.createOffer(
    function(offer){
      pearConnection.setLocalDescription(new RTCSessionDescription(offer));
      sendEvent('send_offer', offer);
    },
    function(error){ console.log(error) }
  )
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
  try {
    if ( pearConnection ) {
      if ( localStream ) pearConnection.removeStream(localStream);
      pearConnection = null;
      pearConnection.close();
    }
  } catch(e) {}
}

/*--- ScreenShot ---*/
function makeScreenshot(options) {
  options = options || {};
  chrome.tabs.captureVisibleTab(null, { format: "png" }, createImage.bind(options));
}

function createCanvas(canvasWidth, canvasHeight) {
  var canvas = document.createElement("canvas");
  canvas.width = canvasWidth;
  canvas.height = canvasHeight;
  return canvas;
}

function createImage(dataURL) {
  var options = this;

  if (!options.width || !options.height) {
    sendEvent('screenshot', {screenshot_id: options.screenshot_id, image: dataURL});
    return
  }

  var canvas = createCanvas(options.width, options.height);
  var context = canvas.getContext('2d');
  var croppedImage = new Image();

  croppedImage.onload = function() {
    // parameter 1: source image (screenshot)
    // parameter 2: source image x coordinate
    // parameter 3: source image y coordinate
    // parameter 4: source image width
    // parameter 5: source image height
    // parameter 6: destination x coordinate
    // parameter 7: destination y coordinate
    // parameter 8: destination width
    // parameter 9: destination height
    context.drawImage(croppedImage, (options.x || 0), (options.y || 0), options.width, options.height, 0, 0, options.width, options.height);
    sendEvent('screenshot', {screenshot_id: options.screenshot_id, image: canvas.toDataURL()});
  };
  croppedImage.src = dataURL;
}