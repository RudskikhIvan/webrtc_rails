var localStream = null;
var partners = {};
var pearConnection = null;
var VERSION = '1.3.0';
var appTabs = appTabs || {};

chrome.extension.onMessage.addListener(function(request){
  if (request && request.type) onEvent(request.type, request.data, request.clientId);
});

function onEvent(type, data, clientId) {
  chrome.windows.getCurrent(function(window){
    chrome.tabs.query({active: true, windowId: window.id}, function(tabs){
      var app;
      if ( appTabs[ clientId ] ) {
        app = appTabs[clientId];
      } else {
        app = new AppTab(tabs[0].id);
        appTabs[clientId] = app;
      }
      switch (type) {
        case 'start_capture' : app.startCapture(data); break;
        case 'stop_capture' : app.stopCapture(data); break;
        case 'handle_answer' : app.handleAnswer(data); break;
        case 'remote_candidate' : app.handleRemoteICECandidate(data); break;
        case 'make_screenshot' : app.makeScreenshot(data); break;
        case 'version' : app.sendEvent('version', VERSION)
      }
    });
  });
}

function AppTab(tabId) {
  this.tabId = tabId;
  this.pearConnection = null;
}

AppTab.prototype.sendEvent = function(type, data) {
  chrome.tabs.sendMessage(this.tabId, {type: type, data: data});
}

AppTab.prototype.startCapture = function(params) {
  var _self = this;
  this.stopCapture();
  this.captureParams = params;
  chrome.desktopCapture.chooseDesktopMedia(["screen", "window"], function(desktop_id){ _self.onAccessApproved(desktop_id) });
}

AppTab.prototype.stopCapture = function() {
  if ( !localStream ) return;
  var track = localStream.getTracks()[0];
  if ( track ) track.stop();
  localStream.active = false;
  localStream = null;
}


AppTab.prototype.onAccessApproved = function(desktop_id) {
  if (!desktop_id) { return; }

  navigator.webkitGetUserMedia(this.captureOptions(desktop_id), gotStream, getUserMediaError);

  var _self = this;
  function gotStream(stream) {
    localStream = stream;
    _self.createConnection(stream);
  }

  function getUserMediaError(e) {
    console.log('getUserMediaError: ' + JSON.stringify(e, null, '---'));
  }
}

AppTab.prototype.captureOptions = function(desktop_id) {
  return {
    audio: false,
    video: {
      mandatory: {
        chromeMediaSource: 'desktop',
        chromeMediaSourceId: desktop_id,
        //minWidth: captureParams.minWidth || 1280,
        maxWidth: this.captureParams.maxWidth || 1280,
        //minHeight: captureParams.minHeight || 720,
        maxHeight: this.captureParams.maxHeight || 720
      }
    }
  }
}

AppTab.prototype.createConnection = function(stream) {
  var _self = this;
  if (this.pearConnection) this.disconnect();
  stream.addEventListener('ended', this.onStreamEnded.bind(this));
  this.localICECandidates = [];
  this.pearConnection = new webkitRTCPeerConnection({iceServers: []});
  this.pearConnection.addStream(stream);
  this.pearConnection.addEventListener('icecandidate', this.handleLocalICECandidate.bind(_self));
  this.pearConnection.createOffer(
    function(offer){
      _self.pearConnection.setLocalDescription(new RTCSessionDescription(offer));
      _self.sendEvent('send_offer', offer);
    },
    function(error){ console.log(error) }
  )
}

AppTab.prototype.onStreamEnded = function(){
  this.sendEvent('stream_ended');
}

AppTab.prototype.handleAnswer = function(answer) {
  this.pearConnection.setRemoteDescription(new RTCSessionDescription(answer));
}

AppTab.prototype.handleLocalICECandidate = function(event) {
  candidate = event.candidate
  if (candidate) {
    this.localICECandidates.push(candidate);
    this.sendEvent('send_candidate', candidate);
  }
  else {
    this.sendEvent('send_candidates', this.localICECandidates);
  }
}

AppTab.prototype.handleRemoteICECandidate = function(candidate) {
  this.pearConnection.addIceCandidate(new RTCIceCandidate(candidate))
}

AppTab.prototype.disconnect = function(){
  try {
    if ( this.pearConnection ) {
      if ( localStream ) this.pearConnection.removeStream(localStream);
      this.pearConnection.close();
      this.pearConnection = null;
    }
  } catch(e) {}
}

// /*--- ScreenShot ---*/
// AppTab.prototype.makeScreenshot = function(options) {
//   options = options || {};
//   chrome.tabs.captureVisibleTab(null, { format: "png" }, createImage.bind(options));
// }

// AppTab.prototype.createCanvas = function(canvasWidth, canvasHeight) {
//   var canvas = document.createElement("canvas");
//   canvas.width = canvasWidth;
//   canvas.height = canvasHeight;
//   return canvas;
// }

// AppTab.prototype.createImage = function(dataURL) {
//   var options = this;

//   if (!options.width || !options.height) {
//     sendEvent('screenshot', {screenshot_id: options.screenshot_id, image: dataURL});
//     return
//   }

//   var canvas = createCanvas(options.width, options.height);
//   var context = canvas.getContext('2d');
//   var croppedImage = new Image();

//   croppedImage.onload = function() {
//     // parameter 1: source image (screenshot)
//     // parameter 2: source image x coordinate
//     // parameter 3: source image y coordinate
//     // parameter 4: source image width
//     // parameter 5: source image height
//     // parameter 6: destination x coordinate
//     // parameter 7: destination y coordinate
//     // parameter 8: destination width
//     // parameter 9: destination height
//     context.drawImage(croppedImage, (options.x || 0), (options.y || 0), options.width, options.height, 0, 0, options.width, options.height);
//     sendEvent('screenshot', {screenshot_id: options.screenshot_id, image: canvas.toDataURL()});
//   };
//   croppedImage.src = dataURL;
// }