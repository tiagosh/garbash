FROM debian:12.1-slim

RUN apt update && apt-get install -y jq

ADD garbash.sh /
ENTRYPOINT /bin/bash /garbash.sh /tmp/ast.json
