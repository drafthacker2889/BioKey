# BioKey Architecture & Developer Guide

## System Architecture

```

                   Android Client (Kotlin)                
              Keystroke Capture + Local Sync              

                      HTTPS/TLS

           API Gateway / Load Balancer (optional)         
                   (Nginx / HAProxy)                      

                     

        Backend Server (Ruby Sinatra + Puma)             
     
   Authentication & Authorization Layer               
   - Rate limiting (IP + Username based)             
   - Session management                              
   - JWT/Bearer token support                        
     
     
   Biometric Verification Engine                      
   - AuthService: Core keystroke analysis            
   - AdvancedBiometricAnalysis: ML-ready features    
   - Adaptive threshold calibration                  
   - Anomaly detection signals                       
     
     
   Request Processing Pipeline                        
   - ApiVersionMiddleware (v1 API versioning)        
   - StructuredLogger (JSON logging, correlation)   
   - ConnectionPool (DB connection management)       
   - ResilientDb (automatic retry & recovery)       
  - Redis-backed rate limiting when REDIS_URL is set
  - Async admin job queue for exports/evaluations
     
     
   Admin Dashboard & Evaluation                       
   - DashboardService (metrics aggregation)          
   - EvaluationService (FAR/FRR/EER computation)    
   - Data export & dataset generation                
     

                      Connection Pool

        PostgreSQL Database (Optimized Schema)            
     
   Core Tables:                                       
   - users (user credentials)                         
   - biometric_profiles (trained keystroke data)     
   - user_score_history (verification attempts)      
   - user_score_thresholds (adaptive calibration)   
   - access_logs (authentication audit trail)        
     
     
   Security & Compliance Tables:                     
   - audit_logs (sensitive operations)               
   - failed_login_attempts (intrusion tracking)     
   - admin_actions (privilege operations)            
   - active_sessions (token management)              
   - user_roles (RBAC)                               
  - async_jobs (queued admin work metadata)          
     
     
   Performance Optimizations:                         
   - Strategic indexes on hot queries                
   - Materialized views for dashboards               
   - Connection pooling via PgBouncer               
   - Query optimization and analysis                 
     

```

## Module Structure

### Core Modules

#### 1. **AuthService** (`lib/auth_service.rb`)
Implements keystroke-dynamics biometric verification with adaptive thresholding.

**Key Classes/Methods:**
- `normalize_attempt_timing()` - Parse keystroke timing data
- `verify_login()` - Main authentication decision logic
- `calibrated_thresholds_for_user()` - Adaptive threshold management
- `weighted_variance_aware_score()` - Statistical distance calculation
- `update_profile()` - Online learning from correct attempts

**Algorithms:**
- Mahalanobis distance with Huber weighting for outlier robustness
- Z-score normalization with coverage ratio penalties
- Variance-aware scoring for keystroke pairs with different consistency

#### 2. **AdvancedBiometricAnalysis** (`lib/advanced_biometric_analysis.rb`)
Novel machine learning features for improved security and explainability.

**Key Methods:**
- `detect_covariate_shift()` - KS test for behavior change detection
- `keystroke_entropy()` - Shannon entropy for keystroke pattern analysis
- `temporal_consistency_analysis()` - In-session typing speed stability
- `template_age_factor()` - Profile recency/freshness scoring
- `pattern_uniqueness_score()` - Biometric signature strength assessment
- `multi_signal_anomaly_detection()` - Multi-modal anomaly scoring

**Research Contributions:**
- Entropy-based keyboard pattern diversity measurement
- Covariate shift detection for compromised account identification
- Template aging model for adaptive security
- Explainable anomaly score decomposition

#### 3. **DashboardService** (`lib/dashboard_service.rb`)
Real-time analytics and evaluation framework.

**Capabilities:**
- Live authentication feed
- User statistics aggregation
- FAR/FRR/EER computation for biometric evaluation
- Dataset export (JSON/CSV) for research

#### 4. **EvaluationService** (`lib/evaluation_service.rb`)
Research-grade biometric system evaluation and validation.

**Metrics Computed:**
- False Acceptance Rate (FAR)
- False Rejection Rate (FRR)
- Equal Error Rate (EER)
- ROC curve generation
- AUC computation

### Infrastructure Modules

#### **StructuredLogger** (`lib/structured_logger.rb`)
Production-grade JSON logging with request correlation.

```ruby
logger.with_request_context(request_id, user_id, api_version)
logger.info("Authentication", matched_pairs: 8, score: 1.25)
```

Outputs:
```json
{
  "timestamp": "2026-02-27T12:34:56Z",
  "level": "INFO",
  "message": "Authentication",
  "request_id": "abc123...",
  "user_id": 42,
  "matched_pairs": 8,
  "score": 1.25
}
```

#### **EnvLoader** (`lib/env_loader.rb`)
Environment configuration with validation and type safety.

```ruby
EnvLoader.load('.env')
db_pool_size = EnvLoader.integer('DB_POOL_SIZE', 10)
require_https = EnvLoader.boolean('APP_REQUIRE_HTTPS', false)
```

#### **ConnectionPool** (`lib/connection_pool.rb`)
Thread-safe connection pooling for PostgreSQL.

```ruby
pool = ConnectionPool.new(config)
pool.with_connection do |conn|
  conn.exec("SELECT * FROM users")
end
```

#### **ResilientDb** (`app.rb`)
Resilient database access with automatic retry and transaction support.

## Data Flow

### Authentication Request Flow

```
1. Client sends: { username, password, typing_data[] }
         
2. API Version Middleware: Route to v1/legacy
         
3. StructuredLogger: Generate request_id, log entry
         
4. Rate Limiter: Check if user/IP exceeded thresholds
         
5. AuthService.verify_login():
    a. Validate user credentials (bcrypt check)
    b. Normalize keystroke timings
    c. Load user's biometric profile from DB
    d. Calculate weighted distance score
    e. Apply coverage penalty if needed
    f. Look up adaptive thresholds
    g. Make decision: SUCCESS | CHALLENGE | ERROR
         
6. AdvancedBiometricAnalysis.multi_signal_anomaly_detection():
    a. Multi-signal anomaly scoring
    b. Entropy analysis
    c. Temporal consistency check
    d. Covariate shift detection
         
7. Record attempt in access_logs & user_score_history
         
8. Return response with X-Request-Id header
         
9. Structured log: Include decision, score, matched_pairs
```

### Profile Adaptation (Online Learning)

```
1. Successful authentication  update_profile()
2. Add attempt to short-term training window
3. Recompute statistics using Welford's algorithm
4. Save updated profile to DB
5. Periodically recalibrate thresholds based on recent scores
```

## API Endpoints

### v1/auth/ - Core Authentication

```
POST   /v1/auth/register      - Create new user
POST   /v1/auth/login         - Authenticate with biometrics
GET    /v1/auth/profile       - Get user profile
POST   /v1/auth/refresh       - Refresh auth token
POST   /v1/auth/logout        - Invalidate session
POST   /v1/train              - Submit training samples
```

### /admin/api/ - Admin & Evaluation

```
GET    /admin/api/overview             - Dashboard metrics
GET    /admin/api/feed                 - Recent attempts
GET    /admin/api/live-feed            - Real-time stream
POST   /admin/api/export-dataset       - Export data
POST   /admin/api/run-evaluation       - Compute FAR/FRR/EER
POST   /admin/api/attempt/:id/label    - Label attempt
POST   /admin/api/attempts/label-bulk  - Batch labeling
```

### /prototype/ - Experimental UI

```
GET    /prototype/login               - Prototype login page
GET    /prototype/feed                - Typing activity feed
GET    /prototype/api/profile         - Profile data
POST   /prototype/api/typing-events   - Stream keystroke events
```

## Configuration & Deployment

### Environment Variables

**Database**
```env
DB_NAME=biokey_db
DB_USER=biokey
DB_PASSWORD=...
DB_HOST=localhost
DB_PORT=5432
DB_POOL_SIZE=10
DB_TIMEOUT=5
```

**API**
```env
API_PORT=4567
API_BIND=0.0.0.0
APP_ENV=production
APP_SESSION_SECRET=...
APP_REQUIRE_HTTPS=true
```

**Logging**
```env
LOG_LEVEL=INFO
LOG_FORMAT=json
ENABLE_STRUCTURED_LOGGING=true
```

**Security**
```env
BCRYPT_COST=12
AUTH_RATE_LIMIT_MAX=30
AUTH_RATE_LIMIT_WINDOW_SECONDS=60
AUTH_LOCKOUT_THRESHOLD=5
AUTH_LOCKOUT_WINDOW_MINUTES=15
```

### Docker Deployment

```bash
# Build
docker build -t biokey-backend:latest ./backend-server

# Run with database
docker-compose -f docker-compose.prod.yml up -d

# View logs
docker-compose -f docker-compose.prod.yml logs -f backend
```

## Testing

### Running Tests

```bash
# All tests
APP_ENV=test bundle exec ruby -I lib:test test/**/*_test.rb

# Specific test file
APP_ENV=test bundle exec ruby -I lib:test test/auth_service_test.rb

# Specific test
APP_ENV=test bundle exec ruby -I lib:test test/auth_service_test.rb -n test_verify_login_success
```

### Test Coverage

- **AuthService**: 30+ tests covering normalization, verification, thresholds
- **AdvancedBiometricAnalysis**: 15+ tests for entropy, anomaly detection, consistency
- **Integration tests**: End-to-end authentication flows
- **Database tests**: Connection pooling, transactions

## Performance Optimization

### Query Optimization

Key optimizations in place:
- User lookup by username (index)
- Biometric profile fetch by user_id (index)
- Recent access logs paginated (index on timestamp)
- Avoid N+1 queries in dashboard

### Caching Strategies

- User session cache (in-memory, TTL-based)
- Profile cache (5-minute TTL) for repeated verifications
- Dashboard aggregate view (materialized view, 1-minute refresh)

### Monitoring

Check query performance:
```sql
EXPLAIN ANALYZE 
SELECT * FROM biometric_profiles WHERE user_id = 1;
```

## Extension Points

### Adding ML Models

Integrate external ML model:

```ruby
def self.predict_spoofing_probability(attempt_data)
  # Call to Python/Go microservice
  result = HTTParty.post('http://ml-service:5000/predict', 
    json: { attempt: attempt_data })
  result['probability']
end
```

### Custom Evaluation Metrics

Add new metric to EvaluationService:

```ruby
def self.equal_error_rate(scores, labels)
  # Implement EER calculation
end
```

### Edge Computing

Deploy verification to mobile:
```ruby
def self.local_verification_enabled?
  ENV['EDGE_COMPUTE_ENABLED'] == 'true'
end
```

## Security Considerations

- All passwords hashed with bcrypt (cost configurable)
- SQL injection prevention via parameterized queries
- Rate limiting prevents brute force attacks
- HTTPS enforcement in production
- Session token rotation
- Audit logging for compliance
- CORS disabled by default

## Contributing

1. Run tests before submitting PR
2. Follow Ruby style guide (RuboCop)
3. Add tests for new features
4. Update documentation
5. Ensure backward API compatibility

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.
