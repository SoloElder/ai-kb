FROM node:20-alpine
WORKDIR /app
COPY server.js package.json ./
COPY public/ public/
RUN npm install --production
VOLUME [ "/app/data" ]
ENV DATA_DIR=/app/data
EXPOSE 3456
CMD ["node", "server.js"]
