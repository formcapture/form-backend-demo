# build stage
FROM node:26.3.0-alpine@sha256:144769ec3f32e8ee36b3cfde91e82bee25d9367b20f31a151f3f7eea3a2a8541 AS build

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
FROM nginx:1.29.4-alpine-slim@sha256:a5459dbb9ed17c9f1eff5448a5dfb22ea3eb386a356e26fc16871dc426ac5383

ARG GIT_COMMIT
ARG APP_VERSION

COPY --from=build /masterportal/dist/mastercode /usr/share/nginx/html/portal/mastercode
COPY default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
