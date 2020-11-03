FROM elixir:1.10.4-alpine

ENV HOME=/opt/app/ TERM=xterm

WORKDIR $HOME

# dev tools
RUN apk update && \
    apk add --no-cache bash curl inotify-tools git

# various dependencies of dependencies
RUN apk add --no-cache \
    ca-certificates openssh-client openssl-dev \
    tzdata \
    gettext 

EXPOSE 4000/tcp
EXPOSE 4001/tcp

# ENTRYPOINT ["iex", "-S", "mix", "phx.server"]
CMD trap 'exit' INT; iex -S mix phx.server