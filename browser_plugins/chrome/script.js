
var clientId = parseInt(Math.random(1) * 10000000);
console.log('capturing plugin inited', clientId);
//Send event to page script
function sendEventToPage(event_name, data) {
    window.postMessage({target: 'screen_capture_frontend', type: event_name, data: data}, '*');
}

function sendEventToBackground(event_name, data, callback) {
    chrome.extension.sendMessage({type: event_name, data: data, clientId: clientId}, callback);
}

function onPageEvent(event_name, data) {
    sendEventToBackground(event_name, data);
}

function onBackgroundEvent(event_name, data) {
    sendEventToPage(event_name, data)
}

window.addEventListener("message", function(event) {
    if (event.data.target && event.data.target == 'screen_capture_backend') {
        onPageEvent(event.data.type, event.data.data);
    }
}, false);


chrome.extension.onMessage.addListener(function(req){
    if (req && req.type) onBackgroundEvent(req.type, req.data);
});