FROM alpine:3.9

LABEL "com.github.actions.name"="Oh My Zsh Pull Request triage"
LABEL "com.github.actions.description"="Triage a Pull Request based on the changes"
LABEL "com.github.actions.icon"="archive"
LABEL "com.github.actions.color"="blue"

LABEL "repository"="http://github.com/ohmyzsh/github-actions"
LABEL "homepage"="http://github.com/ohmyzsh/github-actions"
LABEL "maintainer"="Marc Cornellà <marc.cornella@live.com>"

RUN apk add --no-cache \
    zsh \
    curl \
    git \
    jq

ADD entrypoint.zsh /usr/bin/entrypoint.zsh

ENTRYPOINT ["entrypoint.zsh"]
