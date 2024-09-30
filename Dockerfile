# -------------------------------
# Builder Stage
# -------------------------------
FROM golang:1.20-buster AS builder

# Set environment variables for consistency
ENV APP_DIR=/app

# Create application directory
WORKDIR ${APP_DIR}

# Copy go.mod and go.sum files first for better caching
COPY ./src/go.mod ./src/go.sum ./

# Download dependencies
RUN go mod download

# Copy the source code
COPY ./src/ ./

# Build the Go application
RUN go build -o app .

# -------------------------------
# Final Stage
# -------------------------------
FROM debian:bullseye-slim

# Set environment variables
ENV BIN_DIR=/usr/local/bin

# Create application directory
WORKDIR ${BIN_DIR}

# Install necessary packages
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        bc \
        ca-certificates \
        curl \
        jq \
        vim \
        libzip-dev \
        procps \
        unzip \
        zip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install yq
RUN curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o yq && \
    chmod +x yq

# Copy the Go binary from the builder stage
COPY --from=builder /app/app ${BIN_DIR}/app

# Copy additional binaries (ensure no 'app' directory is present here)
COPY ./src/bin/ ${BIN_DIR}/

# Ensure all binaries are executable
RUN chmod +x ${BIN_DIR}/*

# Expose the application port
EXPOSE 9199

# Create a non-root user
RUN useradd -ms /bin/bash nonrootuser

# Change ownership of the binary directory
RUN chown -R nonrootuser:nonrootuser ${BIN_DIR}

# Switch to the non-root user
USER nonrootuser

# Define the entrypoint
ENTRYPOINT ["/usr/local/bin/app"]
    