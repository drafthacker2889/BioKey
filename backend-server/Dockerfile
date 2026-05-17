# Production-ready Dockerfile for BioKey Backend
FROM ruby:3.2-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    postgresql-dev \
    git

# Copy Gemfile and install gems
COPY Gemfile Gemfile.lock* ./
RUN bundle config set deployment 'true' && \
    bundle config set without 'development test' && \
    bundle install

# ========== Production Stage ==========
FROM ruby:3.2-alpine

WORKDIR /app

# Install runtime dependencies only
RUN apk add --no-cache \
    postgresql-client \
    curl \
    tzdata

# Copy gems from builder
COPY --from=builder /usr/local/bundle /usr/local/bundle

# Copy application code
COPY . .

# Create non-root user for security
RUN addgroup -g 1000 biokey && \
    adduser -D -u 1000 -G biokey biokey && \
    chown -R biokey:biokey /app

USER biokey

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:4567/health || exit 1

# Expose port
EXPOSE 4567

# Set environment
ENV RACK_ENV=production \
    BUNDLE_PATH=/usr/local/bundle

# Start application
CMD ["bundle", "exec", "puma", "-c", "puma.rb"]
