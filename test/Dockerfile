FROM ubuntu:26.04 AS builder

RUN apt update && \
	apt install -y build-essential git cmake zlib1g-dev libuv1-dev libwebsockets-dev libjson-c-dev

RUN git clone https://github.com/tsl0922/ttyd

WORKDIR /ttyd/build

RUN cmake ..

RUN make

FROM ubuntu:26.04

COPY --from=builder /ttyd/build/ttyd /usr/bin/ttyd

ENTRYPOINT ["/usr/bin/ttyd"]
CMD []
