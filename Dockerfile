FROM alpine:latest AS build

RUN apk add --update hugo

WORKDIR /opt/HugoApp

COPY . .
# Add analytics
COPY layouts/partials/head.html themes/hugo-blog-awesome/layouts/partials/head.html

RUN hugo

FROM nginx:1.25-alpine

WORKDIR /usr/share/nginx/html

COPY --from=build /opt/HugoApp/public .

EXPOSE 80/tcp
