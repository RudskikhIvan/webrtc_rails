$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "webrtc_rails/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "webrtc_rails"
  s.version     = WebrtcRails::VERSION
  s.authors     = ["Shredder"]
  s.email       = ["shredder-rull@yandex.ru"]
  s.homepage    = "http://www.webrtc-example.com"
  s.summary     = "Simple WebRTC classes"
  s.description = "Simple WebRTC classes based on Faye (websocket)"
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency "rails", "~> 4.2.0"
  s.add_dependency "jquery-rails", "~> 4.0"
  s.add_dependency "faye-rails"

  s.add_development_dependency "sqlite3"
end
