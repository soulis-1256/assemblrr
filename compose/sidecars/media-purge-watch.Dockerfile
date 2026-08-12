# Built on the host so inotify/curl/jq are in the image, not apk'd at every start.
FROM alpine:3.21
RUN apk add --no-cache bash curl jq inotify-tools
WORKDIR /scripts
ENTRYPOINT ["bash"]
