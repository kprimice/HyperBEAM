FROM ubuntu:22.04

# 1. Install OS dependencies and rustup
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    pkg-config \
    ncurses-dev \
    libssl-dev \
    python3 \
    python-is-python3 \
    curl \
    && curl --proto '=https' --tlsv1.2 https://sh.rustup.rs | sh -s -- -y

ENV PATH="/root/.cargo/bin:${PATH}"

# 2. Build Erlang/OTP
RUN git clone --branch maint-27 https://github.com/erlang/otp.git /tmp/otp \
    && cd /tmp/otp \
    && ./configure \
    && make -j16 \
    && make install \
    && rm -rf /tmp/otp

# 3. Install rebar3
RUN git clone https://github.com/erlang/rebar3.git /tmp/rebar3 \
    && cd /tmp/rebar3 \
    && ./bootstrap \
    && mv rebar3 /usr/local/bin/ \
    && rm -rf /tmp/rebar3

# 4. Copy source and build
WORKDIR /app
COPY . /app

# Optional, but ensures a clean build if something leaked in:
RUN rm -rf _build

RUN rebar3 compile

CMD ["/bin/bash"]