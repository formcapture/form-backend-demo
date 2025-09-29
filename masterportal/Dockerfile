# build stage
FROM node:24.9.0-alpine@sha256:77f3c4d1f33c17dfa4af4b0add57d86957187873e313c2c37f52831d117645c8 AS build

# libs are needed to build the masterportal
RUN apk update && apk add --no-cache --virtual .gyp \
    make \
    g++ \
    pkgconfig \
    pixman-dev \
    cairo-dev \
    pango-dev \
    python3 \
    libc6-compat \
    git

WORKDIR /masterportal

ARG MP_TAG=3.11.0

RUN git clone https://geowerkstatt-hamburg@bitbucket.org/geowerkstatt-hamburg/masterportal.git . && git checkout v${MP_TAG}
RUN git clone https://github.com/formcapture/masterportal-addons.git masterportal-addons && cp -r masterportal-addons/addons/* addons/

# Always use version as folder name
RUN sed -i 's/return folderName;/return stableVersionNumber;/g' devtools/tasks/getMastercodeVersionFolderName.js
RUN npm ci && echo "" | npm run build

# webserver stage
FROM nginx:1.29.1-alpine-slim@sha256:904b648603e4a215bdbb1b91f0ecd4625f47941e41f71340bdafe763c3865760

ARG GIT_COMMIT
ARG APP_VERSION

COPY --from=build /masterportal/dist/mastercode /usr/share/nginx/html/portal/mastercode
COPY default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
