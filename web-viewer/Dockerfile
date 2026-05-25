FROM node:22-slim AS build

ARG SIGNALING_SERVER=127.0.0.1

WORKDIR /app
COPY src/package.json src/.npmrc ./
RUN npm install
COPY src/ .
RUN sed -i "s|\"server\":.*|\"server\": \"${SIGNALING_SERVER}\",|" stream.config.json
RUN npm run build

FROM node:22-slim
RUN npm install -g serve@14
WORKDIR /app
COPY --from=build /app/dist ./dist
EXPOSE 5173
CMD ["serve", "-s", "dist", "-l", "5173"]
