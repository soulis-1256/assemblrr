# Built on the host (not through Gluetun) so Alpine packages never go out the VPN.
FROM alpine:3.24.4
RUN apk add --no-cache bash curl jq docker-cli
WORKDIR /scripts
ENTRYPOINT ["bash"]
