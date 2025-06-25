# build stage
FROM node:24.2.0-alpine@sha256:7aaba6b13a55a1d78411a1162c1994428ed039c6bbef7b1d9859c25ada1d7cc5 AS build

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
FROM nginx:1.28.0-alpine-slim@sha256:39a9a15e0a81914a96fa9ffa980cdfe08e2e5e73ae3424f341ad1f470147c413

ARG GIT_COMMIT
ARG APP_VERSION

COPY --from=build /masterportal/dist/mastercode /usr/share/nginx/html/portal/mastercode
COPY default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
