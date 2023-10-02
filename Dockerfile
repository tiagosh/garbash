FROM debian:12.1-slim

RUN apt update && apt-get install -y jq
RUN apt-get install -y curl
RUN curl -LJO 'https://github.com/tidwall/jj/releases/download/v1.9.2/jj-1.9.2-linux-amd64.tar.gz' && tar xvf jj-1.9.2-linux-amd64.tar.gz && cp jj-1.9.2-linux-amd64/jj /usr/local/bin

ADD garbash.sh /
ENTRYPOINT [ "/bin/bash", "garbash.sh" ]
