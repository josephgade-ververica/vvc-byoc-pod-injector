# Build stage
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download || true
COPY main.go .
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -o /webhook-server .

# Runtime stage
FROM alpine:3.19
RUN apk --no-cache add ca-certificates
COPY --from=builder /webhook-server /webhook-server
EXPOSE 8443
ENTRYPOINT ["/webhook-server"]
