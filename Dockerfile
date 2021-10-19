FROM node:14.17
COPY . .
RUN npm install
EXPOSE 3000
ENTRYPOINT ["node", "server.js"]

