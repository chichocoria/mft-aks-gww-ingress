FROM node:13-alpine

WORKDIR /code
COPY package.json .
RUN npm install
COPY public ./public
COPY src ./src

EXPOSE 3001

ENTRYPOINT ["npm", "start"]
