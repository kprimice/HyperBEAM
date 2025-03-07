FROM debian:bookworm AS build

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    pkg-config \
    ncurses-dev \
    libssl-dev \
    sudo \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/erlang/otp.git /tmp/otp \
    && cd /tmp/otp \
    && git checkout maint-27 \
    # Minimal configure flags: skipping WX, debugger, observer, et
    && ./configure --without-wx --without-debugger --without-observer --without-et \
    --enable-smp-support --enable-m64-build \
    && make -j"$(nproc)" \
    && sudo make install \
    && cd / && rm -rf /tmp/otp

RUN git clone https://github.com/erlang/rebar3.git /tmp/rebar3 \
    && cd /tmp/rebar3 \
    && ./bootstrap \
    && sudo mv rebar3 /usr/local/bin/ \
    && cd / && rm -rf /tmp/rebar3

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /build

COPY . /build

RUN rebar3 as prod release

FROM debian:bookworm AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV PATH="/usr/local/lib/erlang/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    ncurses-base \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/lib/erlang /usr/local/lib/erlang
COPY --from=build /usr/local/bin/rebar3 /usr/local/bin/rebar3

WORKDIR /app
COPY --from=build /build/_build/prod/rel/hb/ /app

EXPOSE 10000

CMD ["/bin/bash"]