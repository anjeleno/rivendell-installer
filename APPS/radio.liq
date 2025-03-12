#!/usr/bin/liquidsoap

#message =
#  "The Savonet team thanks you for using liquidsoap, " ^
#  "and we hope you'll enjoy it!"


set("log.file.path","/home/rd/logs/ls.log")


# We're 48k!
set("frame.audio.samplerate",48000)
# Grab JACK input
radio = mksafe(input.jack(id="liquidsoap"))


output.icecast(%mp3(bitrate=192), host = "localhost", port = 8000, password = "hackme$",
mount = "/192", genre = "Electronic", url = "192",
name = ":: Station Name :: Your Slogan ::", description = "",
format = "audio/mpeg", icy_metadata = "true", radio)


# note, the password above is the source password for icecast2.