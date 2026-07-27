# provisioning-engine — Restate durable-execution service (ADR-0019 Phase 2a).
# Build via the Tekton node/linux channel (ADR-0017) or `docker build`.
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json ./
RUN npm install
COPY prisma ./prisma
RUN npx prisma generate
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package.json ./
RUN npm install --omit=dev
# Carry the generated Prisma client + query engine from the build stage.
COPY --from=build /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=build /app/node_modules/@prisma ./node_modules/@prisma
COPY --from=build /app/dist ./dist
USER 1000
EXPOSE 9080
CMD ["node", "dist/index.js"]
