# build stage
FROM node:22.23.5-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a AS build

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

ARG MP_TAG=3.17.1

RUN git clone https://geowerkstatt-hamburg@bitbucket.org/geowerkstatt-hamburg/masterportal.git . && git checkout v${MP_TAG}
RUN git clone https://github.com/formcapture/masterportal-addons.git masterportal-addons && cp -r masterportal-addons/addons/* addons/

# Always use version as folder name
RUN sed -i -E 's/return folderName(\.replace\(.*\))?;/return stableVersionNumber;/' devtools/tasks/getMastercodeVersionFolderName.js \
    && grep -q 'return stableVersionNumber;' devtools/tasks/getMastercodeVersionFolderName.js
# canvas (native module) misses #include <cstdint>, which current GCC no longer includes implicitly
RUN CXXFLAGS="-include cstdint" npm ci && echo "" | npm run build

# webserver stage
FROM nginx:1.30.8-alpine-slim@sha256:e9eaa7298465eab06d618c51556fdcf3fb5061f9ff40bd28ee898fbd7ee7f900

ARG GIT_COMMIT
ARG APP_VERSION

COPY --from=build /masterportal/dist/mastercode /usr/share/nginx/html/portal/mastercode
COPY default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
