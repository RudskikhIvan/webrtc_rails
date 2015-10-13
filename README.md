#WebRTC Rails

This gem provides easy [WebRTC](https://webrtc.org) communication in any Rails app, based on websocket synchronization (Faye)

## Installation

1. Add to Gemfile and update the bundle

    ```Ruby
    gem 'webrtc_rails', :github => 'shredder-rull/webrtc_rails'
    ```

    Now run `bundle install` to download and install the gem.

2. Add Faye server to the Rails middleware stack like so:
    ```ruby
    # application.rb
    config.middleware.use FayeRails::Middleware, mount: '/faye', :timeout => 25
    ```

3. Add to application.js
    ```javascript
    //= require webrtc_rails
    ```

4. Using:
    ```coffeescript
        client = new WebRTC.Client
            url: 'http://localhost:3000/faye'
            guid: '#{current_user.id}'
            roomUrl: 'your_room_path'
            iceServers: [{ "url": "stun:stun.palava.tv" }]

        client.bind 'local_stream', (stream)->
            WebRTC.attachMediaStream $('#myVideo').get(0), stream

        client.bind 'partner.stream', (partner)->
            WebRTC.attachMediaStream $('#partnerVideo').get(0), partner.stream
    ```