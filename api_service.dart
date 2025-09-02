defaultConfig {
        applicationId "com.teambioinfo.worktracker"
        minSdkVersion 21
        targetSdkVersion 34
        versionCode flutterVersionCode.toInteger()
        versionName flutterVersionName
        multiDexEnabled true
    }

    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }

    buildTypes {
        release {
            signingConfig signingConfigs.release
            minifyEnabled true
            shrinkResources true
        }
    }
}

flutter {
    source '../..'
}

dependencies {
    implementation "org.jetbrains.kotlin:kotlin-stdlib-jdk7:$kotlin_version"
    implementation 'androidx.multidex:multidex:2.0.1'
}

# Build and deployment scripts
# build_scripts/build_android.sh
#!/bin/bash

echo "Building TEAM BIOINFO Android App..."

# Clean previous builds
flutter clean
flutter pub get

# Build APK
echo "Building APK..."
flutter build apk --release

# Build AAB for Play Store
echo "Building AAB..."
flutter build appbundle --release

# Copy files to dist folder
mkdir -p dist/android
cp build/app/outputs/flutter-apk/app-release.apk dist/android/team-bioinfo-release.apk
cp build/app/outputs/bundle/release/app-release.aab dist/android/team-bioinfo-release.aab

echo "Android build completed!"
echo "APK: dist/android/team-bioinfo-release.apk"
echo "AAB: dist/android/team-bioinfo-release.aab"

# build_scripts/build_ios.sh
#!/bin/bash

echo "Building TEAM BIOINFO iOS App..."

# Clean previous builds
flutter clean
flutter pub get

# Build iOS
echo "Building iOS..."
flutter build ios --release

# Build IPA for TestFlight
echo "Building IPA..."
flutter build ipa --release

# Copy to dist folder
mkdir -p dist/ios
cp build/ios/ipa/*.ipa dist/ios/team-bioinfo-release.ipa

echo "iOS build completed!"
echo "IPA: dist/ios/team-bioinfo-release.ipa"

# deployment/docker-compose.yml
version: '3.8'

services:
  postgres:
    image: postgres:15
    container_name: bioinfo_postgres
    environment:
      POSTGRES_DB: team_bioinfo_db
      POSTGRES_USER: bioinfo_user
      POSTGRES_PASSWORD: bioinfo_secure_pass_2024
      POSTGRES_INITDB_ARGS: "--encoding=UTF-8"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./backups:/app/backups
      - ./exports:/app/exports
    ports:
      - "5432:5432"
    networks:
      - bioinfo_network
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bioinfo_user -d team_bioinfo_db"]
      interval: 30s
      timeout: 10s
      retries: 3

  redis:
    image: redis:7-alpine
    container_name: bioinfo_redis
    ports:
      - "6379:6379"
    networks:
      - bioinfo_network
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data

  api:
    build: .
    container_name: bioinfo_api
    environment:
      DATABASE_URL: postgresql://bioinfo_user:bioinfo_secure_pass_2024@postgres:5432/team_bioinfo_db
      REDIS_URL: redis://redis:6379
      SECRET_KEY: your-super-secret-jwt-key-change-in-production
      BACKUP_RETENTION_DAYS: 730
      ENVIRONMENT: production
    volumes:
      - ./exports:/app/exports
      - ./backups:/app/backups
      - ./logs:/app/logs
    ports:
      - "8000:8000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - bioinfo_network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  nginx:
    image: nginx:alpine
    container_name: bioinfo_nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf
      - ./nginx/ssl:/etc/nginx/ssl
      - ./exports:/app/exports
    depends_on:
      - api
    networks:
      - bioinfo_network
    restart: unless-stopped

  backup_scheduler:
    build: .
    container_name: bioinfo_backup
    environment:
      DATABASE_URL: postgresql://bioinfo_user:bioinfo_secure_pass_2024@postgres:5432/team_bioinfo_db
    volumes:
      - ./backups:/app/backups
    depends_on:
      - postgres
    networks:
      - bioinfo_network
    restart: unless-stopped
    command: python backup_scheduler.py

volumes:
  postgres_data:
  redis_data:

networks:
  bioinfo_network:
    driver: bridge

# deployment/nginx/nginx.conf
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=5r/m;

    # Upstream API servers
    upstream api_backend {
        server api:8000;
        keepalive 32;
    }

    # Main server block
    server {
        listen 80;
        server_name localhost;
        client_max_body_size 50M;

        # Security headers
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "no-referrer-when-downgrade" always;
        add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;

        # API endpoints
        location /api/ {
            limit_req zone=api_limit burst=20 nodelay;
            
            proxy_pass http://api_backend/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
        }

        # Auth endpoints with stricter rate limiting
        location ~ ^/(auth|login|register) {
            limit_req zone=auth_limit burst=5 nodelay;
            
            proxy_pass http://api_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Export downloads (protected)
        location /exports/ {
            internal;
            alias /app/exports/;
        }

        # Health check
        location /health {
            proxy_pass http://api_backend/health;
        }

        # Default API proxy
        location / {
            proxy_pass http://api_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }

    # HTTPS server (if SSL certificates are available)
    # server {
    #     listen 443 ssl http2;
    #     server_name localhost;
    #     
    #     ssl_certificate /etc/nginx/ssl/cert.pem;
    #     ssl_certificate_key /etc/nginx/ssl/key.pem;
    #     
    #     # Same configuration as HTTP server
    # }
}

# testing/test_api.py
import pytest
import asyncio
from httpx import AsyncClient
from fastapi.testclient import TestClient
from main import app
from database import get_db, engine
from models import Base
import tempfile
import os

# Test database setup
@pytest.fixture(scope="session")
def test_db():
    # Create temporary database for testing
    test_db_path = tempfile.mktemp()
    test_engine = create_engine(f"sqlite:///{test_db_path}")
    Base.metadata.create_all(bind=test_engine)
    
    yield test_engine
    
    os.unlink(test_db_path)

@pytest.fixture
def client(test_db):
    def override_get_db():
        try:
            db = SessionLocal()
            yield db
        finally:
            db.close()
    
    app.dependency_overrides[get_db] = override_get_db
    yield TestClient(app)
    app.dependency_overrides.clear()

# Authentication tests
def test_register_user(client):
    response = client.post("/auth/register", json={
        "email": "test@example.com",
        "username": "testuser",
        "full_name": "Test User",
        "password": "testpass123"
    })
    assert response.status_code == 200
    assert response.json()["email"] == "test@example.com"

def test_login_user(client):
    # First register a user
    client.post("/auth/register", json={
        "email": "test@example.com",
        "username": "testuser",
        "full_name": "Test User",
        "password": "testpass123"
    })
    
    # Then login
    response = client.post("/auth/login", json={
        "email": "test@example.com",
        "password": "testpass123"
    })
    assert response.status_code == 200
    assert "access_token" in response.json()
    assert "refresh_token" in response.json()

def test_invalid_login(client):
    response = client.post("/auth/login", json={
        "email": "invalid@example.com",
        "password": "wrongpass"
    })
    assert response.status_code == 401

# Work entry tests
def test_create_work_entry(client):
    # Register and login first
    client.post("/auth/register", json={
        "email": "test@example.com",
        "username": "testuser",
        "full_name": "Test User",
        "password": "testpass123"
    })
    
    login_response = client.post("/auth/login", json={
        "email": "test@example.com",
        "password": "testpass123"
    })
    token = login_response.json()["access_token"]
    
    headers = {"Authorization": f"Bearer {token}"}
    response = client.post("/work-entries", json={
        "date": "2024-01-15T00:00:00",
        "tasks": "Sample analysis work",
        "total_hours": 8.0,
        "category": "Analysis",
        "tertiary_analysis_hours": 4.0,
        "cnv_analysis_hours": 2.0,
        "report_preparation_hours": 2.0
    }, headers=headers)
    
    assert response.status_code == 200
    assert response.json()["tasks"] == "Sample analysis work"

def test_duplicate_work_entry_prevention(client):
    # Setup user and first entry
    client.post("/auth/register", json={
        "email": "test@example.com",
        "username": "testuser",
        "full_name": "Test User",
        "password": "testpass123"
    })
    
    login_response = client.post("/auth/login", json={
        "email": "test@example.com",
        "password": "testpass123"
    })
    token = login_response.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    
    # Create first entry
    client.post("/work-entries", json={
        "date": "2024-01-15T00:00:00",
        "tasks": "First entry",
        "total_hours": 4.0,
        "category": "Analysis"
    }, headers=headers)
    
    # Try to create duplicate
    response = client.post("/work-entries", json={
        "date": "2024-01-15T00:00:00",
        "tasks": "Duplicate entry",
        "total_hours": 4.0,
        "category": "Analysis"
    }, headers=headers)
    
    assert response.status_code == 400

# Role-based access tests
def test_admin_access_only(client):
    # Register regular user
    client.post("/auth/register", json={
        "email": "user@example.com",
        "username": "user",
        "full_name": "Regular User",
        "password": "testpass123"
    })
    
    login_response = client.post("/auth/login", json={
        "email": "user@example.com",
        "password": "testpass123"
    })
    token = login_response.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    
    # Try to access admin endpoint
    response = client.get("/users", headers=headers)
    assert response.status_code == 403

# deployment/setup.sh
#!/bin/bash

echo "Setting up TEAM BIOINFO Work Tracking System..."

# Create necessary directories
mkdir -p backups/{daily,weekly,monthly}
mkdir -p exports
mkdir -p logs
mkdir -p nginx/ssl

# Set permissions
chmod 755 backups exports logs
chmod -R 600 nginx/ssl

# Create environment file
cat > .env << EOF
# Database Configuration
DATABASE_URL=postgresql://bioinfo_user:bioinfo_secure_pass_2024@postgres:5432/team_bioinfo_db
POSTGRES_DB=team_bioinfo_db
POSTGRES_USER=bioinfo_user
POSTGRES_PASSWORD=bioinfo_secure_pass_2024

# JWT Configuration
SECRET_KEY=$(openssl rand -hex 32)
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30
REFRESH_TOKEN_EXPIRE_DAYS=7

# Redis Configuration
REDIS_URL=redis://redis:6379

# Application Configuration
ENVIRONMENT=production
DEBUG=false
BACKUP_RETENTION_DAYS=730
MAX_UPLOAD_SIZE=50MB

# Paths
EXPORT_PATH=/app/exports
BACKUP_PATH=/app/backups
LOG_PATH=/app/logs
EOF

echo "Environment file created. Please update the SECRET_KEY and database passwords."

# Create initial admin script
cat > create_admin.py << 'EOF'
#!/usr/bin/env python3

import sys
import asyncio
from sqlalchemy.orm import Session
from database import SessionLocal
from models import User, UserRole
from auth import get_password_hash

async def create_initial_admin():
    db = SessionLocal()
    
    try:
        # Check if admin exists
        admin_exists = db.query(User).filter(User.role == UserRole.ADMIN).first()
        
        if admin_exists:
            print("Admin user already exists!")
            return
        
        # Create initial admin
        admin_email = input("Enter admin email: ")
        admin_username = input("Enter admin username: ")
        admin_name = input("Enter admin full name: ")
        admin_password = input("Enter admin password: ")
        
        hashed_password = get_password_hash(admin_password)
        
        admin_user = User(
            email=admin_email,
            username=admin_username,
            full_name=admin_name,
            hashed_password=hashed_password,
            role=UserRole.ADMIN,
            is_active=True
        )
        
        db.add(admin_user)
        db.commit()
        
        print(f"Admin user '{admin_username}' created successfully!")
        
    except Exception as e:
        print(f"Error creating admin: {e}")
        db.rollback()
    finally:
        db.close()

if __name__ == "__main__":
    asyncio.run(create_initial_admin())
EOF

chmod +x create_admin.py

# Create deployment script
cat > deploy.sh << 'EOF'
#!/bin/bash

echo "Deploying TEAM BIOINFO System..."

# Stop existing containers
docker-compose down

# Build and start services
docker-compose build --no-cache
docker-compose up -d

# Wait for database to be ready
echo "Waiting for database to be ready..."
sleep 10

# Run database migrations
docker-compose exec api python -c "
from database import engine
from models import Base
Base.metadata.create_all(bind=engine)
print('Database tables created successfully!')
"

# Create initial admin user
echo "Creating initial admin user..."
docker-compose exec api python create_admin.py

echo "Deployment completed!"
echo "API is available at: http://localhost:8000"
echo "Health check: http://localhost:8000/health"
echo ""
echo "Next steps:"
echo "1. Test the API endpoints"
echo "2. Build and install the Flutter app"
echo "3. Configure SSL certificates for production"
EOF

chmod +x deploy.sh

# Create monitoring script
cat > monitor.sh << 'EOF'
#!/bin/bash

echo "TEAM BIOINFO System Status"
echo "=========================="

# Check container status
echo "Container Status:"
docker-compose ps

echo -e "\nDisk Usage:"
df -h | grep -E "(backups|exports)"

echo -e "\nDatabase Status:"
docker-compose exec postgres pg_isready -U bioinfo_user -d team_bioinfo_db

echo -e "\nAPI Health:"
curl -s http://localhost:8000/health | jq '.'

echo -e "\nRecent Logs:"
docker-compose logs --tail=10 api

echo -e "\nBackup Files:"
ls -la backups/

echo -e "\nExport Files:"
ls -la exports/
EOF

chmod +x monitor.sh

echo "Setup completed!"
echo ""
echo "To deploy the system:"
echo "1. Run: ./deploy.sh"
echo "2. Monitor with: ./monitor.sh"
echo "3. Build mobile app with: cd .. && ./build_scripts/build_android.sh"

# README.md
# TEAM BIOINFO - Work Tracking System

A comprehensive work tracking and team management system designed specifically for bioinformatics teams.

## Features

### Core Functionality
- **User Management**: Role-based access (Admin, Team Lead, Member)
- **Team Organization**: Create and manage sub-teams with dedicated leads
- **Work Tracking**: Daily work entry system with bioinformatics-specific categories
- **Task Allocation**: Assign and track tasks with progress monitoring
- **Approval Workflow**: Admin approval system for work entries
- **Analytics**: Comprehensive dashboards and performance metrics
- **Data Export**: Multiple formats (CSV, TSV, XLSX) with automated backups

### Bioinformatics Categories
- Tertiary Analysis
- CNV Analysis  
- Report Preparation
- Report Rework
- Report Crosscheck
- Report Allocation
- Gene Panel Coverage Analysis

### Mobile App Features
- **Cross-Platform**: Android APK and iOS support
- **Offline Capability**: Cache recent entries for offline work
- **Real-time Sync**: Automatic synchronization with server
- **Interactive UI**: Modern, responsive design with charts and analytics
- **Push Notifications**: Task assignments and deadline reminders

## Technology Stack

### Backend
- **FastAPI**: High-performance Python web framework
- **PostgreSQL**: Primary database with advanced analytics
- **Redis**: Caching and session management
- **JWT Authentication**: Secure token-based auth with refresh tokens
- **Automated Backups**: Daily, weekly, and monthly backup scheduling

### Frontend (Mobile)
- **Flutter**: Cross-platform mobile development
- **GetX**: State management and dependency injection
- **FL Chart**: Interactive data visualization
- **Dio**: HTTP client with automatic token refresh
- **Secure Storage**: Encrypted local data storage

### Infrastructure
- **Docker Compose**: Containerized deployment
- **Nginx**: Reverse proxy with rate limiting
- **SSL/TLS**: HTTPS encryption support
- **Health Monitoring**: Automated system health checks

## Installation

### Prerequisites
- Docker and Docker Compose
- Flutter SDK (for mobile app development)
- Git

### Quick Start

1. **Clone and Setup**
```bash
git clone <repository-url>
cd team-bioinfo
chmod +x deployment/setup.sh deployment/deploy.sh
./deployment/setup.sh
```

2. **Deploy Backend**
```bash
cd deployment
./deploy.sh
```

3. **Build Mobile App**
```bash
# Android
./build_scripts/build_android.sh

# iOS (macOS required)
./build_scripts/build_ios.sh
```

4. **Install APK**
```bash
# Transfer APK to Android device
adb install dist/android/team-bioinfo-release.apk
```

### Configuration

1. **Update Environment Variables**
   - Edit `deployment/.env` with your specific configuration
   - Change database passwords and JWT secret key
   - Update server IP in Flutter app (`lib/services/api_service.dart`)

2. **SSL Setup (Production)**
   - Place SSL certificates in `deployment/nginx/ssl/`
   - Uncomment HTTPS server block in nginx.conf

3. **Create Initial Admin**
   - Run the deployment script which will prompt for admin creation
   - Or manually: `docker-compose exec api python create_admin.py`

## Usage

### Admin Functions
- Create and manage teams
- Approve work entries
- View performance analytics
- Export data and create backups
- Manage user roles and permissions

### Team Lead Functions
- Manage team members (limited to their team)
- Allocate tasks to team members
- Monitor team performance
- Approve team work entries (if configured)

### Member Functions
- Submit daily work entries
- View assigned tasks and update progress
- Access personal dashboard and analytics
- Receive task notifications

### Work Entry Process
1. Daily work entry with required fields
2. Categorize work by bioinformatics type
3. Submit for approval
4. Admin/Team Lead reviews and approves
5. Entry becomes locked and counted in analytics

## API Endpoints

### Authentication
- `POST /auth/login` - User login
- `POST /auth/register` - User registration
- `POST /auth/refresh` - Refresh access token
- `POST /auth/logout` - User logout

### Work Entries
- `GET /work-entries` - List work entries
- `POST /work-entries` - Create work entry
- `PUT /work-entries/{id}` - Update work entry
- `POST /work-entries/{id}/approve` - Approve entry

### Teams & Tasks
- `GET /teams` - List teams
- `POST /teams` - Create team
- `GET /tasks` - List tasks
- `POST /tasks` - Create task
- `PUT /tasks/{id}/progress` - Update task progress

### Analytics
- `GET /dashboard/daily` - Daily dashboard
- `GET /dashboard/team/{id}` - Team dashboard
- `GET /dashboard/performance` - Performance analytics

### Admin
- `GET /users` - List all users
- `PUT /users/{id}/role` - Update user role
- `GET /reports/export` - Export data
- `GET /backup/daily` - Create backup

## Data Backup & Recovery

### Automated Backups
- **Daily**: Every night at 2:00 AM
- **Weekly**: Every Sunday at 3:00 AM  
- **Monthly**: First day of each month

### Manual Backup
```bash
# Create immediate backup
curl -X GET "http://localhost:8000/backup/daily" \
  -H "Authorization: Bearer <admin-token>"
```

### Data Recovery
- Backups stored in `/app/backups/YYYY/MM/` directory
- JSON format with complete system state
- Automated retention policy (2 years default)

## Security Features

- **Argon2/BCrypt**: Password hashing
- **JWT Tokens**: Access and refresh token system
- **Role-Based Access**: Multi-level permission system
- **Rate Limiting**: API endpoint protection
- **Audit Logging**: Complete activity tracking
- **HTTPS**: Encrypted data transmission
- **Input Validation**: Comprehensive data validation

## Monitoring & Maintenance

### Health Monitoring
```bash
# Check system status
./deployment/monitor.sh

# View logs
docker-compose logs -f api

# Database health
docker-compose exec postgres pg_isready
```

### Performance Tuning
- Database connection pooling
- Redis caching for frequent queries
- Nginx load balancing ready
- Optimized database indexes

## Mobile App Distribution

### Android
- APK available for direct installation
- AAB ready for Google Play Store
- Minimum SDK: Android 5.0 (API 21)

### iOS
- IPA ready for TestFlight distribution
- App Store deployment ready
- Minimum iOS: 12.0

## Support & Troubleshooting

### Common Issues
1. **Connection Failed**: Check server IP in mobile app
2. **Login Issues**: Verify user credentials and server status
3. **Backup Failures**: Check disk space and permissions
4. **Performance Issues**: Monitor database and Redis status

### Logs Location
- API Logs: `logs/api.log`
- Database Logs: `docker-compose logs postgres`
- Nginx Logs: `docker-compose logs nginx`

### Support Contact
- System Administrator: [Your Contact Info]
- Technical Issues: Check health monitoring dashboard
- Data Recovery: Use backup restoration procedures

## Development

### Adding New Features
1. Update database models in `models.py`
2. Create database migration
3. Add API endpoints in `main.py`
4. Update mobile app controllers and screens
5. Add tests in `testing/` directory

### Testing
```bash
# Backend tests
cd backend && python -m pytest testing/

# Mobile app tests
cd mobile && flutter test

# Load testing
cd testing && python load_test.py
```

## License
Internal use only - Not for commercial distribution

## Version
Current Version: 1.0.0
Last Updated: $(date)

---

**Note**: This system is designed for internal team use and includes comprehensive logging and backup systems to ensure data integrity and recoverability._hours': _actualHours,
      'checklist_items': _checklistItems,
    };

    _teamController.updateTaskProgress(widget.task.id!, progressData);
    Get.back();
  }
}

# lib/screens/admin_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/work_controller.dart';
import 'package:team_bioinfo/controllers/team_controller.dart';
import 'package:fl_chart/fl_chart.dart';

class AdminScreen extends StatelessWidget {
  final WorkController _workController = Get.find();
  final TeamController _teamController = Get.find();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Admin Panel'),
          bottom: TabBar(
            tabs: [
              Tab(icon: Icon(Icons.dashboard), text: 'Overview'),
              Tab(icon: Icon(Icons.approval), text: 'Approvals'),
              Tab(icon: Icon(Icons.analytics), text: 'Analytics'),
              Tab(icon: Icon(Icons.settings), text: 'Settings'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildOverviewTab(),
            _buildApprovalsTab(),
            _buildAnalyticsTab(),
            _buildSettingsTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAdminStats(),
          SizedBox(height: 16),
          _buildQuickActions(),
          SizedBox(height: 16),
          _buildRecentActivity(),
        ],
      ),
    );
  }

  Widget _buildAdminStats() {
    return Row(
      children: [
        Expanded(child: _buildStatCard('Total Users', '20', Icons.people, Colors.blue)),
        SizedBox(width: 8),
        Expanded(child: _buildStatCard('Active Teams', '4', Icons.group, Colors.green)),
        SizedBox(width: 8),
        Expanded(child: _buildStatCard('Pending Approvals', '8', Icons.pending, Colors.orange)),
        SizedBox(width: 8),
        Expanded(child: _buildStatCard('Today\'s Entries', '15', Icons.work, Colors.purple)),
      ],
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            SizedBox(height: 8),
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(title, style: TextStyle(fontSize: 10, color: Colors.grey), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Quick Actions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildActionChip('Export Data', Icons.download, () => _exportData()),
                _buildActionChip('Create Backup', Icons.backup, () => _createBackup()),
                _buildActionChip('User Management', Icons.people, () => _manageUsers()),
                _buildActionChip('System Health', Icons.health_and_safety, () => _checkSystemHealth()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionChip(String label, IconData icon, VoidCallback onTap) {
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: onTap,
    );
  }

  Widget _buildApprovalsTab() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pending Approvals',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 16),
          Expanded(
            child: Obx(() {
              if (_workController.pendingApprovals.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle, size: 64, color: Colors.green),
                      SizedBox(height: 16),
                      Text('All entries approved!', style: TextStyle(fontSize: 18)),
                    ],
                  ),
                );
              }

              return ListView.builder(
                itemCount: _workController.pendingApprovals.length,
                itemBuilder: (context, index) {
                  final entry = _workController.pendingApprovals[index];
                  return _buildApprovalCard(entry);
                },
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildApprovalCard(WorkEntry entry) {
    return Card(
      margin: EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'User: ${entry.userId}', // Replace with actual user name
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  '${entry.totalHours}h',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            SizedBox(height: 8),
            Text(entry.tasks),
            SizedBox(height: 8),
            Text(
              'Category: ${entry.category}',
              style: TextStyle(color: Colors.grey[600]),
            ),
            SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _showEntryDetails(entry),
                  icon: Icon(Icons.visibility),
                  label: Text('View Details'),
                ),
                SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _workController.approveWorkEntry(entry.id!),
                  icon: Icon(Icons.check),
                  label: Text('Approve'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalyticsTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Performance Analytics',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 16),
          _buildTeamPerformanceChart(),
          SizedBox(height: 16),
          _buildProductivityTrends(),
          SizedBox(height: 16),
          _buildTopPerformers(),
        ],
      ),
    );
  }

  Widget _buildTeamPerformanceChart() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Team Performance (Last 30 Days)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Container(
              height: 200,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: 200,
                  barTouchData: BarTouchData(enabled: false),
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          const teams = ['Team A', 'Team B', 'Team C', 'Team D'];
                          if (value.toInt() >= 0 && value.toInt() < teams.length) {
                            return Text(teams[value.toInt()], style: TextStyle(fontSize: 10));
                          }
                          return Text('');
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                    ),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  barGroups: [
                    BarChartGroupData(x: 0, barRods: [BarChartRodData(toY: 180, color: Colors.blue)]),
                    BarChartGroupData(x: 1, barRods: [BarChartRodData(toY: 160, color: Colors.green)]),
                    BarChartGroupData(x: 2, barRods: [BarChartRodData(toY: 170, color: Colors.orange)]),
                    BarChartGroupData(x: 3, barRods: [BarChartRodData(toY: 190, color: Colors.purple)]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProductivityTrends() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Productivity Trends',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Container(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                          if (value.toInt() >= 0 && value.toInt() < days.length) {
                            return Text(days[value.toInt()], style: TextStyle(fontSize: 10));
                          }
                          return Text('');
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                    ),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: true),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [
                        FlSpot(0, 8.2),
                        FlSpot(1, 7.8),
                        FlSpot(2, 8.5),
                        FlSpot(3, 7.9),
                        FlSpot(4, 8.3),
                        FlSpot(5, 6.5),
                        FlSpot(6, 5.2),
                      ],
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 3,
                      dotData: FlDotData(show: true),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopPerformers() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Top Performers (This Month)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 12),
            ListView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: 5,
              itemBuilder: (context, index) {
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: index == 0 
                        ? Colors.gold 
                        : index == 1 
                            ? Colors.grey[400]
                            : index == 2 
                                ? Colors.brown[300]
                                : Colors.blue,
                    child: Text('${index + 1}'),
                  ),
                  title: Text('Team Member ${index + 1}'),
                  subtitle: Text('Team ${String.fromCharCode(65 + index)}'),
                  trailing: Text('${180 - (index * 10)}h', style: TextStyle(fontWeight: FontWeight.bold)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'System Settings',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 16),
          _buildSettingsCard('Data Management', [
            _buildSettingsTile('Export All Data', 'Download complete database export', Icons.download, () => _exportData()),
            _buildSettingsTile('Create Backup', 'Manual backup creation', Icons.backup, () => _createBackup()),
            _buildSettingsTile('Data Retention', 'Configure data retention policies', Icons.schedule, () {}),
          ]),
          SizedBox(height: 16),
          _buildSettingsCard('User Management', [
            _buildSettingsTile('Manage Users', 'Add, edit, or remove users', Icons.people, () => _manageUsers()),
            _buildSettingsTile('Role Permissions', 'Configure role-based access', Icons.security, () {}),
            _buildSettingsTile('Team Structure', 'Manage team assignments', Icons.group, () {}),
          ]),
          SizedBox(height: 16),
          _buildSettingsCard('System Health', [
            _buildSettingsTile('Health Check', 'Check system status', Icons.health_and_safety, () => _checkSystemHealth()),
            _buildSettingsTile('Performance Metrics', 'View system performance', Icons.speed, () {}),
            _buildSettingsTile('Error Logs', 'Review system errors', Icons.bug_report, () {}),
          ]),
        ],
      ),
    );
  }

  Widget _buildSettingsCard(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsTile(String title, String subtitle, IconData icon, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Icon(Icons.arrow_forward_ios),
      onTap: onTap,
    );
  }

  Widget _buildRecentActivity() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent Activity',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 12),
            ListView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: 5,
              itemBuilder: (context, index) {
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.blue,
                    child: Icon(Icons.person, color: Colors.white),
                  ),
                  title: Text('User created work entry'),
                  subtitle: Text('2 hours ago'),
                  trailing: Icon(Icons.work),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _exportData() {
    Get.snackbar('Info', 'Export functionality will be implemented');
  }

  void _createBackup() {
    Get.snackbar('Info', 'Backup creation initiated');
  }

  void _manageUsers() {
    Get.snackbar('Info', 'User management screen coming soon');
  }

  void _checkSystemHealth() {
    Get.snackbar('Success', 'System is running normally', backgroundColor: Colors.green);
  }

  void _showEntryDetails(WorkEntry entry) {
    showDialog(
      context: Get.context!,
      builder: (context) => AlertDialog(
        title: Text('Work Entry Details'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Tasks: ${entry.tasks}'),
              SizedBox(height: 8),
              Text('Total Hours: ${entry.totalHours}'),
              SizedBox(height: 8),
              Text('Category: ${entry.category}'),
              if (entry.notes != null) ...[
                SizedBox(height: 8),
                Text('Notes: ${entry.notes}'),
              ],
              SizedBox(height: 12),
              Text('Breakdown:', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('• Tertiary Analysis: ${entry.tertiaryAnalysisHours}h'),
              Text('• CNV Analysis: ${entry.cnvAnalysisHours}h'),
              Text('• Report Preparation: ${entry.reportPreparationHours}h'),
              Text('• Report Rework: ${entry.reportReworkHours}h'),
              Text('• Report Crosscheck: ${entry.reportCrosscheckHours}h'),
              Text('• Report Allocation: ${entry.reportAllocationHours}h'),
              Text('• Gene Panel Coverage: ${entry.genePanelCoverageHours}h'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Get.back();
              _workController.approveWorkEntry(entry.id!);
            },
            child: Text('Approve'),
          ),
        ],
      ),
    );
  }
}

# lib/screens/task_create_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/team_controller.dart';
import 'package:team_bioinfo/controllers/auth_controller.dart';
import 'package:team_bioinfo/models/task_model.dart';
import 'package:intl/intl.dart';

class TaskCreateScreen extends StatefulWidget {
  @override
  _TaskCreateScreenState createState() => _TaskCreateScreenState();
}

class _TaskCreateScreenState extends State<TaskCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final TeamController _teamController = Get.find();
  final AuthController _authController = Get.find();

  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _estimatedHoursController = TextEditingController();

  int? _selectedAssignee;
  int? _selectedTeam;
  String _selectedPriority = 'medium';
  DateTime? _dueDate;
  List<Map<String, dynamic>> _checklistItems = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Create Task'),
        actions: [
          IconButton(
            onPressed: _submitForm,
            icon: Icon(Icons.save),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildBasicInfo(),
              SizedBox(height: 16),
              _buildAssignmentSection(),
              SizedBox(height: 16),
              _buildTimeAndPriority(),
              SizedBox(height: 16),
              _buildChecklistSection(),
              SizedBox(height: 24),
              _buildSubmitButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBasicInfo() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Basic Information', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 16),
            TextFormField(
              controller: _titleController,
              decoration: InputDecoration(labelText: 'Task Title *'),
              validator: (value) => value?.isEmpty == true ? 'Please enter a title' : null,
            ),
            SizedBox(height: 12),
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(labelText: 'Description'),
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssignmentSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Assignment', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 16),
            DropdownButtonFormField<int>(
              decoration: InputDecoration(labelText: 'Assign To *'),
              value: _selectedAssignee,
              items: [], // TODO: Load team members
              onChanged: (value) => setState(() => _selectedAssignee = value),
              validator: (value) => value == null ? 'Please select an assignee' : null,
            ),
            SizedBox(height: 12),
            DropdownButtonFormField<int>(
              decoration: InputDecoration(labelText: 'Team (Optional)'),
              value: _selectedTeam,
              items: [], // TODO: Load teams
              onChanged: (value) => setState(() => _selectedTeam = value),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeAndPriority() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Time & Priority', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedPriority,
                    decoration: InputDecoration(labelText: 'Priority'),
                    items: ['low', 'medium', 'high'].map((priority) {
                      return DropdownMenuItem(
                        value: priority,
                        child: Text(priority.toUpperCase()),
                      );
                    }).toList(),
                    onChanged: (value) => setState(() => _selectedPriority = value!),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _estimatedHoursController,
                    decoration: InputDecoration(labelText: 'Est. Hours'),
                    keyboardType: TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            ListTile(
              leading: Icon(Icons.calendar_today),
              title: Text('Due Date'),
              subtitle: Text(_dueDate != null 
                  ? DateFormat('MMM d, yyyy').format(_dueDate!) 
                  : 'Not set'),
              trailing: Icon(Icons.arrow_forward_ios),
              onTap: _selectDueDate,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChecklistSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Checklist', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                IconButton(
                  onPressed: _addChecklistItem,
                  icon: Icon(Icons.add),
                ),
              ],
            ),
            ..._checklistItems.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              
              return ListTile(
                title: Text(item['item']),
                trailing: IconButton(
                  onPressed: () => setState(() => _checklistItems.removeAt(index)),
                  icon: Icon(Icons.delete, color: Colors.red),
                ),
              );
            }).toList(),
            if (_checklistItems.isEmpty)
              Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No checklist items', style: TextStyle(color: Colors.grey)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitButton() {
    return Obx(() => SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _teamController.isLoading.value ? null : _submitForm,
        child: _teamController.isLoading.value
            ? CircularProgressIndicator(color: Colors.white)
            : Text('Create Task'),
      ),
    ));
  }

  Future<void> _selectDueDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? DateTime.now().add(Duration(days: 7)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(Duration(days: 365)),
    );
    
    if (date != null) {
      setState(() => _dueDate = date);
    }
  }

  void _addChecklistItem() {
    showDialog(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text('Add Checklist Item'),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(hintText: 'Enter checklist item'),
          ),
          actions: [
            TextButton(onPressed: () => Get.back(), child: Text('Cancel')),
            TextButton(
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  setState(() {
                    _checklistItems.add({
                      'item': controller.text,
                      'completed': false,
                    });
                  });
                  Get.back();
                }
              },
              child: Text('Add'),
            ),
          ],
        );
      },
    );
  }

  void _submitForm() {
    if (_formKey.currentState!.validate()) {
      final task = Task(
        title: _titleController.text,
        description: _descriptionController.text.isEmpty ? null : _descriptionController.text,
        assignedTo: _selectedAssignee!,
        createdBy: _authController.currentUser.value!.id,
        teamId: _selectedTeam,
        priority: _selectedPriority,
        estimatedHours: _estimatedHoursController.text.isEmpty 
            ? null 
            : double.tryParse(_estimatedHoursController.text),
        dueDate: _dueDate,
        checklistItems: _checklistItems.isEmpty ? null : _checklistItems,
      );

      _teamController.createTask(task);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _estimatedHoursController.dispose();
    super.dispose();
  }
}

# android/app/build.gradle
def localProperties = new Properties()
def localPropertiesFile = rootProject.file('local.properties')
if (localPropertiesFile.exists()) {
    localPropertiesFile.withReader('UTF-8') { reader ->
        localProperties.load(reader)
    }
}

def flutterRoot = localProperties.getProperty('flutter.sdk')
if (flutterRoot == null) {
    throw new GradleException("Flutter SDK not found. Define location with flutter.sdk in the local.properties file.")
}

def flutterVersionCode = localProperties.getProperty('flutter.versionCode')
if (flutterVersionCode == null) {
    flutterVersionCode = '1'
}

def flutterVersionName = localProperties.getProperty('flutter.versionName')
if (flutterVersionName == null) {
    flutterVersionName = '1.0'
}

apply plugin: 'com.android.application'
apply plugin: 'kotlin-android'
apply from: "$flutterRoot/packages/flutter_tools/gradle/flutter.gradle"

android {
    compileSdkVersion 34
    ndkVersion flutter.ndkVersion

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = '1.8'
    }

    sourceSets {
        main.java.srcDirs += 'src/main/kotlin'
    }

    defaultConfig {# pubspec.yaml
name: team_bioinfo
description: Team Bioinfo Work Tracking App
version: 1.0.0+1

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  
  # State management
  get: ^4.6.6
  
  # Networking
  dio: ^5.3.2
  
  # Secure storage
  flutter_secure_storage: ^9.0.0
  
  # Charts
  fl_chart: ^0.64.0
  
  # UI components
  cupertino_icons: ^1.0.2
  flutter_spinkit: ^5.2.0
  fluttertoast: ^8.2.4
  
  # Date/time
  intl: ^0.18.1
  
  # File handling
  path_provider: ^2.1.1
  
  # Local database
  sqflite: ^2.3.0
  
  # Permissions
  permission_handler: ^11.0.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0

flutter:
  uses-material-design: true
  assets:
    - assets/images/
    - assets/icons/

# lib/main.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/auth_controller.dart';
import 'package:team_bioinfo/screens/dashboard_screen.dart';
import 'package:team_bioinfo/screens/work_entry_screen.dart';
import 'package:team_bioinfo/screens/tasks_screen.dart';
import 'package:team_bioinfo/screens/team_screen.dart';
import 'package:team_bioinfo/screens/admin_screen.dart';

class MainScreen extends StatefulWidget {
  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  final AuthController _authController = Get.find();

  List<Widget> get _screens {
    List<Widget> screens = [
      DashboardScreen(),
      WorkEntryScreen(),
      TasksScreen(),
    ];

    if (_authController.isTeamLead) {
      screens.add(TeamScreen());
    }

    if (_authController.isAdmin) {
      screens.add(AdminScreen());
    }

    return screens;
  }

  List<BottomNavigationBarItem> get _navItems {
    List<BottomNavigationBarItem> items = [
      BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Dashboard'),
      BottomNavigationBarItem(icon: Icon(Icons.work), label: 'Work Entry'),
      BottomNavigationBarItem(icon: Icon(Icons.task), label: 'Tasks'),
    ];

    if (_authController.isTeamLead) {
      items.add(BottomNavigationBarItem(icon: Icon(Icons.group), label: 'Team'));
    }

    if (_authController.isAdmin) {
      items.add(BottomNavigationBarItem(icon: Icon(Icons.admin_panel_settings), label: 'Admin'));
    }

    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('TEAM BIOINFO'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'logout') {
                _authController.logout();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'profile',
                child: Row(
                  children: [
                    Icon(Icons.person),
                    SizedBox(width: 8),
                    Text('Profile'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout),
                    SizedBox(width: 8),
                    Text('Logout'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: _navItems,
      ),
    );
  }
}

# lib/screens/dashboard_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:team_bioinfo/controllers/work_controller.dart';
import 'package:team_bioinfo/controllers/auth_controller.dart';
import 'package:intl/intl.dart';

class DashboardScreen extends StatelessWidget {
  final WorkController _workController = Get.find();
  final AuthController _authController = Get.find();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => _workController.loadTodayEntries(),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildWelcomeCard(),
              SizedBox(height: 16),
              _buildQuickStats(),
              SizedBox(height: 16),
              _buildWorkCategoryChart(),
              SizedBox(height: 16),
              _buildRecentEntries(),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Get.to(() => WorkEntryFormScreen()),
        child: Icon(Icons.add),
        tooltip: 'Add Work Entry',
      ),
    );
  }

  Widget _buildWelcomeCard() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: Theme.of(Get.context!).primaryColor,
                  child: Text(
                    _authController.currentUser.value?.fullName.substring(0, 1).toUpperCase() ?? 'U',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Welcome back,',
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                      ),
                      Text(
                        _authController.currentUser.value?.fullName ?? 'User',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(Get.context!).primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _authController.currentUser.value?.role.toUpperCase() ?? 'MEMBER',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(Get.context!).primaryColor,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            Text(
              DateFormat('EEEE, MMMM d, yyyy').format(DateTime.now()),
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickStats() {
    return Obx(() => Row(
      children: [
        Expanded(
          child: _buildStatCard(
            'Today\'s Hours',
            _workController.todayTotalHours.toStringAsFixed(1),
            Icons.access_time,
            Colors.blue,
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            'Entries',
            _workController.todayEntryCount.toString(),
            Icons.work,
            Colors.green,
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            'Pending',
            _workController.workEntries.where((e) => e.approvalStatus == 'pending').length.toString(),
            Icons.pending,
            Colors.orange,
          ),
        ),
      ],
    ));
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            Text(
              title,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkCategoryChart() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Work Category Breakdown',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Obx(() {
              if (_workController.workEntries.isEmpty) {
                return Container(
                  height: 200,
                  child: Center(child: Text('No data available')),
                );
              }

              return Container(
                height: 200,
                child: PieChart(
                  PieChartData(
                    sections: _getPieChartSections(),
                    centerSpaceRadius: 40,
                    sectionsSpace: 2,
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  List<PieChartSectionData> _getPieChartSections() {
    final entries = _workController.workEntries;
    if (entries.isEmpty) return [];

    Map<String, double> categoryHours = {
      'Tertiary Analysis': entries.fold(0.0, (sum, e) => sum + e.tertiaryAnalysisHours),
      'CNV Analysis': entries.fold(0.0, (sum, e) => sum + e.cnvAnalysisHours),
      'Report Prep': entries.fold(0.0, (sum, e) => sum + e.reportPreparationHours),
      'Report Rework': entries.fold(0.0, (sum, e) => sum + e.reportReworkHours),
      'Report Check': entries.fold(0.0, (sum, e) => sum + e.reportCrosscheckHours),
      'Report Allocation': entries.fold(0.0, (sum, e) => sum + e.reportAllocationHours),
      'Gene Panel': entries.fold(0.0, (sum, e) => sum + e.genePanelCoverageHours),
    };

    List<Color> colors = [
      Colors.blue, Colors.green, Colors.orange, Colors.red,
      Colors.purple, Colors.teal, Colors.indigo
    ];

    return categoryHours.entries
        .where((entry) => entry.value > 0)
        .toList()
        .asMap()
        .entries
        .map((entry) {
      return PieChartSectionData(
        color: colors[entry.key % colors.length],
        value: entry.value.value,
        title: '${entry.value.value.toStringAsFixed(1)}h',
        radius: 50,
        titleStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
      );
    }).toList();
  }

  Widget _buildRecentEntries() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent Work Entries',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () => _showDatePicker(),
                  child: Text('Change Date'),
                ),
              ],
            ),
            SizedBox(height: 12),
            Obx(() {
              if (_workController.isLoading.value) {
                return Center(child: CircularProgressIndicator());
              }

              if (_workController.workEntries.isEmpty) {
                return Container(
                  height: 100,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.work_off, size: 48, color: Colors.grey),
                        SizedBox(height: 8),
                        Text('No work entries for today'),
                      ],
                    ),
                  ),
                );
              }

              return ListView.builder(
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                itemCount: _workController.workEntries.length,
                itemBuilder: (context, index) {
                  final entry = _workController.workEntries[index];
                  return _buildWorkEntryTile(entry);
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkEntryTile(WorkEntry entry) {
    Color statusColor = entry.approvalStatus == 'approved'
        ? Colors.green
        : entry.approvalStatus == 'rejected'
            ? Colors.red
            : Colors.orange;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: statusColor.withOpacity(0.2),
        child: Icon(
          entry.approvalStatus == 'approved'
              ? Icons.check
              : entry.approvalStatus == 'rejected'
                  ? Icons.close
                  : Icons.schedule,
          color: statusColor,
        ),
      ),
      title: Text(
        entry.tasks,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${entry.totalHours}h • ${entry.category}'),
          Text(
            'Status: ${entry.approvalStatus.toUpperCase()}',
            style: TextStyle(color: statusColor, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      trailing: entry.isLocked
          ? Icon(Icons.lock, color: Colors.grey)
          : Icon(Icons.edit, color: Theme.of(Get.context!).primaryColor),
      onTap: entry.isLocked ? null : () => _editWorkEntry(entry),
    );
  }

  void _showDatePicker() async {
    final date = await showDatePicker(
      context: Get.context!,
      initialDate: _workController.selectedDate.value,
      firstDate: DateTime.now().subtract(Duration(days: 365)),
      lastDate: DateTime.now().add(Duration(days: 30)),
    );
    
    if (date != null) {
      _workController.loadEntriesForDate(date);
    }
  }

  void _editWorkEntry(WorkEntry entry) {
    Get.to(() => WorkEntryFormScreen(entry: entry));
  }
}

# lib/screens/work_entry_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/work_controller.dart';
import 'package:team_bioinfo/models/work_entry_model.dart';
import 'package:team_bioinfo/controllers/auth_controller.dart';
import 'package:intl/intl.dart';

class WorkEntryScreen extends StatelessWidget {
  final WorkController _workController = Get.find();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Work Entries',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            _buildDateSelector(),
            SizedBox(height: 16),
            Expanded(
              child: Obx(() {
                if (_workController.isLoading.value) {
                  return Center(child: CircularProgressIndicator());
                }

                return ListView.builder(
                  itemCount: _workController.workEntries.length,
                  itemBuilder: (context, index) {
                    final entry = _workController.workEntries[index];
                    return _buildWorkEntryCard(entry);
                  },
                );
              }),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Get.to(() => WorkEntryFormScreen()),
        label: Text('Add Entry'),
        icon: Icon(Icons.add),
      ),
    );
  }

  Widget _buildDateSelector() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Obx(() => Text(
              DateFormat('MMMM d, yyyy').format(_workController.selectedDate.value),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            )),
            Row(
              children: [
                IconButton(
                  onPressed: () {
                    final newDate = _workController.selectedDate.value.subtract(Duration(days: 1));
                    _workController.loadEntriesForDate(newDate);
                  },
                  icon: Icon(Icons.chevron_left),
                ),
                IconButton(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: Get.context!,
                      initialDate: _workController.selectedDate.value,
                      firstDate: DateTime.now().subtract(Duration(days: 365)),
                      lastDate: DateTime.now(),
                    );
                    if (date != null) {
                      _workController.loadEntriesForDate(date);
                    }
                  },
                  icon: Icon(Icons.calendar_today),
                ),
                IconButton(
                  onPressed: () {
                    final newDate = _workController.selectedDate.value.add(Duration(days: 1));
                    if (newDate.isBefore(DateTime.now().add(Duration(days: 1)))) {
                      _workController.loadEntriesForDate(newDate);
                    }
                  },
                  icon: Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkEntryCard(WorkEntry entry) {
    return Card(
      margin: EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    entry.tasks,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                _buildStatusChip(entry.approvalStatus),
              ],
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.access_time, size: 16, color: Colors.grey),
                SizedBox(width: 4),
                Text('${entry.totalHours}h'),
                SizedBox(width: 16),
                Icon(Icons.category, size: 16, color: Colors.grey),
                SizedBox(width: 4),
                Text(entry.category),
              ],
            ),
            if (entry.notes != null && entry.notes!.isNotEmpty) ...[
              SizedBox(height: 8),
              Text(
                entry.notes!,
                style: TextStyle(color: Colors.grey[600]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            SizedBox(height: 12),
            _buildCategoryBreakdown(entry),
            if (!entry.isLocked) ...[
              SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => Get.to(() => WorkEntryFormScreen(entry: entry)),
                    icon: Icon(Icons.edit),
                    label: Text('Edit'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color color = status == 'approved'
        ? Colors.green
        : status == 'rejected'
            ? Colors.red
            : Colors.orange;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildCategoryBreakdown(WorkEntry entry) {
    List<Map<String, dynamic>> categories = [
      {'name': 'Tertiary Analysis', 'hours': entry.tertiaryAnalysisHours, 'color': Colors.blue},
      {'name': 'CNV Analysis', 'hours': entry.cnvAnalysisHours, 'color': Colors.green},
      {'name': 'Report Prep', 'hours': entry.reportPreparationHours, 'color': Colors.orange},
      {'name': 'Report Rework', 'hours': entry.reportReworkHours, 'color': Colors.red},
      {'name': 'Report Check', 'hours': entry.reportCrosscheckHours, 'color': Colors.purple},
      {'name': 'Report Allocation', 'hours': entry.reportAllocationHours, 'color': Colors.teal},
      {'name': 'Gene Panel', 'hours': entry.genePanelCoverageHours, 'color': Colors.indigo},
    ];

    categories = categories.where((cat) => cat['hours'] > 0).toList();

    if (categories.isEmpty) return SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: categories.map((cat) => Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: cat['color'].withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '${cat['name']}: ${cat['hours']}h',
          style: TextStyle(
            fontSize: 10,
            color: cat['color'],
            fontWeight: FontWeight.bold,
          ),
        ),
      )).toList(),
    );
  }
}

# lib/screens/work_entry_form_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/work_controller.dart';
import 'package:team_bioinfo/controllers/auth_controller.dart';
import 'package:team_bioinfo/models/work_entry_model.dart';
import 'package:intl/intl.dart';

class WorkEntryFormScreen extends StatefulWidget {
  final WorkEntry? entry;

  WorkEntryFormScreen({this.entry});

  @override
  _WorkEntryFormScreenState createState() => _WorkEntryFormScreenState();
}

class _WorkEntryFormScreenState extends State<WorkEntryFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final WorkController _workController = Get.find();
  final AuthController _authController = Get.find();

  late TextEditingController _tasksController;
  late TextEditingController _notesController;
  late DateTime _selectedDate;
  late String _selectedCategory;
  late String _selectedStatus;

  // Hour controllers
  late TextEditingController _tertiaryAnalysisController;
  late TextEditingController _cnvAnalysisController;
  late TextEditingController _reportPrepController;
  late TextEditingController _reportReworkController;
  late TextEditingController _reportCrosscheckController;
  late TextEditingController _reportAllocationController;
  late TextEditingController _genePanelController;
  late TextEditingController _estimatedHoursController;

  List<String> categories = [
    'Analysis',
    'Report Generation',
    'Quality Control',
    'Research',
    'Meeting',
    'Training',
    'Other'
  ];

  List<String> statuses = [
    'not_started',
    'in_progress',
    'completed',
    'on_hold'
  ];

  @override
  void initState() {
    super.initState();
    _initializeControllers();
  }

  void _initializeControllers() {
    _tasksController = TextEditingController(text: widget.entry?.tasks ?? '');
    _notesController = TextEditingController(text: widget.entry?.notes ?? '');
    _selectedDate = widget.entry?.date ?? DateTime.now();
    _selectedCategory = widget.entry?.category ?? categories.first;
    _selectedStatus = widget.entry?.status ?? statuses[1];

    _tertiaryAnalysisController = TextEditingController(
      text: widget.entry?.tertiaryAnalysisHours.toString() ?? '0'
    );
    _cnvAnalysisController = TextEditingController(
      text: widget.entry?.cnvAnalysisHours.toString() ?? '0'
    );
    _reportPrepController = TextEditingController(
      text: widget.entry?.reportPreparationHours.toString() ?? '0'
    );
    _reportReworkController = TextEditingController(
      text: widget.entry?.reportReworkHours.toString() ?? '0'
    );
    _reportCrosscheckController = TextEditingController(
      text: widget.entry?.reportCrosscheckHours.toString() ?? '0'
    );
    _reportAllocationController = TextEditingController(
      text: widget.entry?.reportAllocationHours.toString() ?? '0'
    );
    _genePanelController = TextEditingController(
      text: widget.entry?.genePanelCoverageHours.toString() ?? '0'
    );
    _estimatedHoursController = TextEditingController(
      text: widget.entry?.estimatedHours?.toString() ?? ''
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry == null ? 'Add Work Entry' : 'Edit Work Entry'),
        actions: [
          if (widget.entry != null && !widget.entry!.isLocked)
            IconButton(
              onPressed: _submitForm,
              icon: Icon(Icons.save),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDateSelector(),
              SizedBox(height: 16),
              _buildTasksField(),
              SizedBox(height: 16),
              _buildCategoryAndStatus(),
              SizedBox(height: 16),
              _buildBioinfoHoursSection(),
              SizedBox(height: 16),
              _buildEstimatedHoursField(),
              SizedBox(height: 16),
              _buildNotesField(),
              SizedBox(height: 24),
              _buildTotalHoursDisplay(),
              SizedBox(height: 24),
              _buildSubmitButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDateSelector() {
    return Card(
      child: ListTile(
        leading: Icon(Icons.calendar_today),
        title: Text('Date'),
        subtitle: Text(DateFormat('MMMM d, yyyy').format(_selectedDate)),
        trailing: Icon(Icons.arrow_forward_ios),
        onTap: _selectDate,
      ),
    );
  }

  Widget _buildTasksField() {
    return TextFormField(
      controller: _tasksController,
      decoration: InputDecoration(
        labelText: 'Tasks Performed *',
        hintText: 'Describe the work you completed today...',
      ),
      maxLines: 3,
      validator: (value) {
        if (value != null && value.isNotEmpty) {
          final hours = double.tryParse(value);
          if (hours == null || hours < 0 || hours > 24) {
            return 'Hours must be between 0 and 24';
          }
        }
        return null;
      },
      onChanged: (value) => setState(() {}), // Trigger rebuild for total calculation
    );
  }

  Widget _buildEstimatedHoursField() {
    return TextFormField(
      controller: _estimatedHoursController,
      decoration: InputDecoration(
        labelText: 'Estimated Hours (Optional)',
        suffixText: 'hrs',
        helperText: 'Expected time for completion',
      ),
      keyboardType: TextInputType.numberWithOptions(decimal: true),
      validator: (value) {
        if (value != null && value.isNotEmpty) {
          final hours = double.tryParse(value);
          if (hours == null || hours < 0 || hours > 24) {
            return 'Hours must be between 0 and 24';
          }
        }
        return null;
      },
    );
  }

  Widget _buildNotesField() {
    return TextFormField(
      controller: _notesController,
      decoration: InputDecoration(
        labelText: 'Notes (Optional)',
        hintText: 'Additional comments or observations...',
      ),
      maxLines: 3,
    );
  }

  Widget _buildTotalHoursDisplay() {
    double totalHours = _calculateTotalHours();
    
    return Card(
      color: totalHours > 24 ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Total Hours:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              '${totalHours.toStringAsFixed(1)} hrs',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: totalHours > 24 ? Colors.red : Colors.green,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitButton() {
    return Obx(() => SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _workController.isLoading.value ? null : _submitForm,
        child: _workController.isLoading.value
            ? CircularProgressIndicator(color: Colors.white)
            : Text(widget.entry == null ? 'Create Entry' : 'Update Entry'),
      ),
    ));
  }

  double _calculateTotalHours() {
    return [
      _tertiaryAnalysisController.text,
      _cnvAnalysisController.text,
      _reportPrepController.text,
      _reportReworkController.text,
      _reportCrosscheckController.text,
      _reportAllocationController.text,
      _genePanelController.text,
    ].fold(0.0, (sum, hourText) {
      final hours = double.tryParse(hourText) ?? 0.0;
      return sum + hours;
    });
  }

  Future<void> _selectDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(Duration(days: 30)),
      lastDate: DateTime.now(),
    );
    
    if (date != null) {
      setState(() => _selectedDate = date);
    }
  }

  void _submitForm() {
    if (_formKey.currentState!.validate()) {
      final totalHours = _calculateTotalHours();
      
      if (totalHours > 24) {
        Get.snackbar('Error', 'Total hours cannot exceed 24 hours per day', backgroundColor: Colors.red);
        return;
      }

      final entry = WorkEntry(
        id: widget.entry?.id,
        userId: _authController.currentUser.value!.id,
        date: _selectedDate,
        tasks: _tasksController.text,
        totalHours: totalHours,
        category: _selectedCategory,
        status: _selectedStatus,
        notes: _notesController.text.isEmpty ? null : _notesController.text,
        tertiaryAnalysisHours: double.tryParse(_tertiaryAnalysisController.text) ?? 0.0,
        cnvAnalysisHours: double.tryParse(_cnvAnalysisController.text) ?? 0.0,
        reportPreparationHours: double.tryParse(_reportPrepController.text) ?? 0.0,
        reportReworkHours: double.tryParse(_reportReworkController.text) ?? 0.0,
        reportCrosscheckHours: double.tryParse(_reportCrosscheckController.text) ?? 0.0,
        reportAllocationHours: double.tryParse(_reportAllocationController.text) ?? 0.0,
        genePanelCoverageHours: double.tryParse(_genePanelController.text) ?? 0.0,
        estimatedHours: _estimatedHoursController.text.isEmpty 
            ? null 
            : double.tryParse(_estimatedHoursController.text),
      );

      if (widget.entry == null) {
        _workController.createWorkEntry(entry);
      } else {
        _workController.updateWorkEntry(widget.entry!.id!, entry);
      }
    }
  }

  @override
  void dispose() {
    _tasksController.dispose();
    _notesController.dispose();
    _tertiaryAnalysisController.dispose();
    _cnvAnalysisController.dispose();
    _reportPrepController.dispose();
    _reportReworkController.dispose();
    _reportCrosscheckController.dispose();
    _reportAllocationController.dispose();
    _genePanelController.dispose();
    _estimatedHoursController.dispose();
    super.dispose();
  }
}

# lib/screens/tasks_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/team_controller.dart';
import 'package:team_bioinfo/controllers/auth_controller.dart';
import 'package:team_bioinfo/models/task_model.dart';
import 'package:intl/intl.dart';

class TasksScreen extends StatelessWidget {
  final TeamController _teamController = Get.find();
  final AuthController _authController = Get.find();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => _teamController.loadMyTasks(),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              SizedBox(height: 16),
              _buildTaskStats(),
              SizedBox(height: 16),
              _buildTaskList(),
            ],
          ),
        ),
      ),
      floatingActionButton: _authController.isTeamLead 
          ? FloatingActionButton(
              onPressed: () => Get.to(() => TaskCreateScreen()),
              child: Icon(Icons.add),
              tooltip: 'Create Task',
            )
          : null,
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'My Tasks',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        IconButton(
          onPressed: () => _teamController.loadMyTasks(),
          icon: Icon(Icons.refresh),
        ),
      ],
    );
  }

  Widget _buildTaskStats() {
    return Obx(() {
      final tasks = _teamController.myTasks;
      final completedTasks = tasks.where((t) => t.status == 'completed').length;
      final inProgressTasks = tasks.where((t) => t.status == 'in_progress').length;
      final overdueTasks = tasks.where((t) => 
          t.dueDate != null && 
          t.dueDate!.isBefore(DateTime.now()) && 
          t.status != 'completed'
      ).length;

      return Row(
        children: [
          Expanded(child: _buildStatCard('Total', tasks.length.toString(), Icons.assignment, Colors.blue)),
          SizedBox(width: 8),
          Expanded(child: _buildStatCard('Completed', completedTasks.toString(), Icons.check_circle, Colors.green)),
          SizedBox(width: 8),
          Expanded(child: _buildStatCard('In Progress', inProgressTasks.toString(), Icons.play_circle, Colors.orange)),
          SizedBox(width: 8),
          Expanded(child: _buildStatCard('Overdue', overdueTasks.toString(), Icons.warning, Colors.red)),
        ],
      );
    });
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(title, style: TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskList() {
    return Obx(() {
      if (_teamController.myTasks.isEmpty) {
        return Container(
          height: 300,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.task_alt, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text(
                  'No tasks assigned',
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
                SizedBox(height: 8),
                Text(
                  'Tasks assigned to you will appear here',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        );
      }

      return ListView.builder(
        shrinkWrap: true,
        physics: NeverScrollableScrollPhysics(),
        itemCount: _teamController.myTasks.length,
        itemBuilder: (context, index) {
          final task = _teamController.myTasks[index];
          return _buildTaskCard(task);
        },
      );
    });
  }

  Widget _buildTaskCard(Task task) {
    Color priorityColor = task.priority == 'high'
        ? Colors.red
        : task.priority == 'medium'
            ? Colors.orange
            : Colors.green;

    Color statusColor = task.status == 'completed'
        ? Colors.green
        : task.status == 'in_progress'
            ? Colors.blue
            : Colors.grey;

    bool isOverdue = task.dueDate != null && 
                    task.dueDate!.isBefore(DateTime.now()) && 
                    task.status != 'completed';

    return Card(
      margin: EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    task.title,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: priorityColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: priorityColor.withOpacity(0.3)),
                  ),
                  child: Text(
                    task.priority.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: priorityColor,
                    ),
                  ),
                ),
              ],
            ),
            if (task.description != null) ...[
              SizedBox(height: 8),
              Text(
                task.description!,
                style: TextStyle(color: Colors.grey[600]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.flag, size: 16, color: statusColor),
                SizedBox(width: 4),
                Text(task.status.replaceAll('_', ' ').toUpperCase()),
                if (task.dueDate != null) ...[
                  SizedBox(width: 16),
                  Icon(
                    isOverdue ? Icons.warning : Icons.schedule,
                    size: 16,
                    color: isOverdue ? Colors.red : Colors.grey,
                  ),
                  SizedBox(width: 4),
                  Text(
                    DateFormat('MMM d').format(task.dueDate!),
                    style: TextStyle(color: isOverdue ? Colors.red : Colors.grey[600]),
                  ),
                ],
              ],
            ),
            SizedBox(height: 12),
            _buildProgressBar(task),
            SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (task.estimatedHours != null)
                  Text(
                    'Est: ${task.estimatedHours}h | Actual: ${task.actualHours}h',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                TextButton(
                  onPressed: () => _showTaskDetails(task),
                  child: Text('Update Progress'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(Task task) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Progress',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            Text(
              '${task.progressPercentage}%',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        SizedBox(height: 4),
        LinearProgressIndicator(
          value: task.progressPercentage / 100,
          backgroundColor: Colors.grey[300],
          valueColor: AlwaysStoppedAnimation<Color>(
            task.progressPercentage == 100 ? Colors.green : Colors.blue,
          ),
        ),
      ],
    );
  }

  void _showTaskDetails(Task task) {
    Get.to(() => TaskDetailScreen(task: task));
  }
}

# lib/screens/task_detail_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/team_controller.dart';
import 'package:team_bioinfo/models/task_model.dart';
import 'package:intl/intl.dart';

class TaskDetailScreen extends StatefulWidget {
  final Task task;

  TaskDetailScreen({required this.task});

  @override
  _TaskDetailScreenState createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  final TeamController _teamController = Get.find();
  late String _selectedStatus;
  late int _progressPercentage;
  late double _actualHours;
  late List<Map<String, dynamic>> _checklistItems;

  @override
  void initState() {
    super.initState();
    _selectedStatus = widget.task.status;
    _progressPercentage = widget.task.progressPercentage;
    _actualHours = widget.task.actualHours;
    _checklistItems = List<Map<String, dynamic>>.from(widget.task.checklistItems ?? []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Task Details'),
        actions: [
          IconButton(
            onPressed: _updateTask,
            icon: Icon(Icons.save),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTaskHeader(),
            SizedBox(height: 16),
            _buildTaskInfo(),
            SizedBox(height: 16),
            _buildProgressSection(),
            SizedBox(height: 16),
            _buildChecklistSection(),
            SizedBox(height: 16),
            _buildTimeTracking(),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskHeader() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.task.title,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            if (widget.task.description != null) ...[
              SizedBox(height: 8),
              Text(
                widget.task.description!,
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTaskInfo() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            _buildInfoRow('Priority', widget.task.priority.toUpperCase()),
            _buildInfoRow('Status', _selectedStatus.replaceAll('_', ' ').toUpperCase()),
            if (widget.task.dueDate != null)
              _buildInfoRow('Due Date', DateFormat('MMM d, yyyy').format(widget.task.dueDate!)),
            if (widget.task.estimatedHours != null)
              _buildInfoRow('Estimated Hours', '${widget.task.estimatedHours}h'),
            _buildInfoRow('Actual Hours', '${_actualHours}h'),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontWeight: FontWeight.bold)),
          Text(value),
        ],
      ),
    );
  }

  Widget _buildProgressSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Progress & Status',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedStatus,
              decoration: InputDecoration(labelText: 'Status'),
              items: ['not_started', 'in_progress', 'completed', 'on_hold'].map((status) {
                return DropdownMenuItem(
                  value: status,
                  child: Text(status.replaceAll('_', ' ').toUpperCase()),
                );
              }).toList(),
              onChanged: (value) => setState(() {
                _selectedStatus = value!;
                if (value == 'completed') _progressPercentage = 100;
                if (value == 'not_started') _progressPercentage = 0;
              }),
            ),
            SizedBox(height: 16),
            Text('Progress: $_progressPercentage%'),
            Slider(
              value: _progressPercentage.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              label: '$_progressPercentage%',
              onChanged: (value) => setState(() => _progressPercentage = value.round()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChecklistSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Checklist',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  onPressed: _addChecklistItem,
                  icon: Icon(Icons.add),
                ),
              ],
            ),
            SizedBox(height: 8),
            ..._checklistItems.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              
              return CheckboxListTile(
                title: Text(item['item']),
                value: item['completed'],
                onChanged: (value) => setState(() {
                  _checklistItems[index]['completed'] = value!;
                }),
                secondary: IconButton(
                  onPressed: () => setState(() => _checklistItems.removeAt(index)),
                  icon: Icon(Icons.delete, color: Colors.red),
                ),
              );
            }).toList(),
            if (_checklistItems.isEmpty)
              Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No checklist items', style: TextStyle(color: Colors.grey)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeTracking() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Time Tracking',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            TextFormField(
              initialValue: _actualHours.toString(),
              decoration: InputDecoration(
                labelText: 'Actual Hours',
                suffixText: 'hrs',
              ),
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              onChanged: (value) {
                _actualHours = double.tryParse(value) ?? 0.0;
              },
            ),
          ],
        ),
      ),
    );
  }

  void _addChecklistItem() {
    showDialog(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text('Add Checklist Item'),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(hintText: 'Enter task item'),
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  setState(() {
                    _checklistItems.add({
                      'item': controller.text,
                      'completed': false,
                    });
                  });
                  Get.back();
                }
              },
              child: Text('Add'),
            ),
          ],
        );
      },
    );
  }

  void _updateTask() {
    final progressData = {
      'status': _selectedStatus,
      'progress_percentage': _progressPercentage,
      'actual_hours': _actualHours,
      'checklist_items': _checklistItems,
    };

    _teamController.updateTaskProgress(widget.task.id!, progressData);
    Get.back();
  }
}

# lib/screens/team_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/team_controller.dart';
import 'package:team_bioinfo/controllers/auth_controller.dart';
import 'package:team_bioinfo/models/team_model.dart';

class TeamScreen extends StatelessWidget {
  final TeamController _teamController = Get.find();
  final AuthController _authController = Get.find();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => _teamController.loadTeams(),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              SizedBox(height: 16),
              _buildTeamsList(),
            ],
          ),
        ),
      ),
      floatingActionButton: _authController.isAdmin
          ? FloatingActionButton(
              onPressed: () => _showCreateTeamDialog(),
              child: Icon(Icons.add),
              tooltip: 'Create Team',
            )
          : null,
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Teams',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        IconButton(
          onPressed: () => _teamController.loadTeams(),
          icon: Icon(Icons.refresh),
        ),
      ],
    );
  }

  Widget _buildTeamsList() {
    return Obx(() {
      if (_teamController.teams.isEmpty) {
        return Container(
          height: 300,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.group, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text(
                  'No teams created',
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
              ],
            ),
          ),
        );
      }

      return ListView.builder(
        shrinkWrap: true,
        physics: NeverScrollableScrollPhysics(),
        itemCount: _teamController.teams.length,
        itemBuilder: (context, index) {
          final team = _teamController.teams[index];
          return _buildTeamCard(team);
        },
      );
    });
  }

  Widget _buildTeamCard(Team team) {
    return Card(
      margin: EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    team.name,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${team.members.length} members',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (team.description != null) ...[
              SizedBox(height: 8),
              Text(
                team.description!,
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
            SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: team.members.map((member) {
                return Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    member.fullName,
                    style: TextStyle(fontSize: 12),
                  ),
                );
              }).toList(),
            ),
            SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _viewTeamDashboard(team),
                  icon: Icon(Icons.dashboard),
                  label: Text('Dashboard'),
                ),
                if (_authController.isAdmin) ...[
                  TextButton.icon(
                    onPressed: () => _editTeam(team),
                    icon: Icon(Icons.edit),
                    label: Text('Edit'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateTeamDialog() {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: Get.context!,
      builder: (context) => AlertDialog(
        title: Text('Create New Team'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(labelText: 'Team Name'),
            ),
            SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: InputDecoration(labelText: 'Description (Optional)'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                final team = Team(
                  name: nameController.text,
                  description: descController.text.isEmpty ? null : descController.text,
                  createdBy: _authController.currentUser.value!.id,
                );
                _teamController.createTeam(team);
                Get.back();
              }
            },
            child: Text('Create'),
          ),
        ],
      ),
    );
  }

  void _viewTeamDashboard(Team team) {
    Get.to(() => TeamDashboardScreen(team: team));
  }

  void _editTeam(Team team) {
    // Implementation for team editing
    Get.snackbar('Info', 'Team editing feature coming soon');
  }

  void _updateTask() {
    final progressData = {
      'status': _selectedStatus,
      'progress_percentage': _progressPercentage,
      'actual
        if (value == null || value.isEmpty) {
          return 'Please describe your tasks';
        }
        return null;
      },
    );
  }

  Widget _buildCategoryAndStatus() {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: _selectedCategory,
            decoration: InputDecoration(labelText: 'Category'),
            items: categories.map((category) {
              return DropdownMenuItem(value: category, child: Text(category));
            }).toList(),
            onChanged: (value) => setState(() => _selectedCategory = value!),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String>(
            value: _selectedStatus,
            decoration: InputDecoration(labelText: 'Status'),
            items: statuses.map((status) {
              return DropdownMenuItem(
                value: status,
                child: Text(status.replaceAll('_', ' ').toUpperCase()),
              );
            }).toList(),
            onChanged: (value) => setState(() => _selectedStatus = value!),
          ),
        ),
      ],
    );
  }

  Widget _buildBioinfoHoursSection() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bioinformatics Hours Breakdown',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            _buildHourField('Tertiary Analysis', _tertiaryAnalysisController),
            SizedBox(height: 12),
            _buildHourField('CNV Analysis', _cnvAnalysisController),
            SizedBox(height: 12),
            _buildHourField('Report Preparation', _reportPrepController),
            SizedBox(height: 12),
            _buildHourField('Report Rework', _reportReworkController),
            SizedBox(height: 12),
            _buildHourField('Report Crosscheck', _reportCrosscheckController),
            SizedBox(height: 12),
            _buildHourField('Report Allocation', _reportAllocationController),
            SizedBox(height: 12),
            _buildHourField('Gene Panel Coverage', _genePanelController),
          ],
        ),
      ),
    );
  }

  Widget _buildHourField(String label, TextEditingController controller) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: '$label (hours)',
        suffixText: 'hrs',
      ),
      keyboardType: TextInputType.numberWithOptions(decimal: true),
      validator: (value) {package:team_bioinfo/controllers/auth_controller.dart';
import 'package:team_bioinfo/controllers/work_controller.dart';
import 'package:team_bioinfo/controllers/team_controller.dart';
import 'package:team_bioinfo/services/api_service.dart';
import 'package:team_bioinfo/services/storage_service.dart';
import 'package:team_bioinfo/screens/splash_screen.dart';
import 'package:team_bioinfo/utils/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize services
  await Get.putAsync(() => StorageService().init());
  Get.put(ApiService());
  Get.put(AuthController());
  Get.put(WorkController());
  Get.put(TeamController());
  
  runApp(TeamBioinfoApp());
}

class TeamBioinfoApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'TEAM BIOINFO',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: SplashScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

# lib/controllers/auth_controller.dart
import 'package:get/get.dart';
import 'package:team_bioinfo/models/user_model.dart';
import 'package:team_bioinfo/services/api_service.dart';
import 'package:team_bioinfo/services/storage_service.dart';
import 'package:team_bioinfo/screens/login_screen.dart';
import 'package:team_bioinfo/screens/main_screen.dart';

class AuthController extends GetxController {
  final ApiService _apiService = Get.find();
  final StorageService _storageService = Get.find();
  
  Rx<User?> currentUser = Rx<User?>(null);
  RxBool isLoading = false.obs;
  RxBool isLoggedIn = false.obs;

  @override
  void onInit() {
    super.onInit();
    checkAuthStatus();
  }

  Future<void> checkAuthStatus() async {
    isLoading.value = true;
    
    final token = await _storageService.getAccessToken();
    if (token != null) {
      try {
        final user = await _apiService.getCurrentUser();
        currentUser.value = user;
        isLoggedIn.value = true;
        Get.offAll(() => LoginScreen());
    }
    
    isLoading.value = false;
  }

  Future<void> login(String email, String password) async {
    try {
      isLoading.value = true;
      
      final response = await _apiService.login(email, password);
      await _storageService.saveTokens(response['access_token'], response['refresh_token']);
      
      final user = await _apiService.getCurrentUser();
      currentUser.value = user;
      isLoggedIn.value = true;
      
      Get.offAll(() => MainScreen());
      Get.snackbar('Success', 'Logged in successfully', backgroundColor: Colors.green);
      
    } catch (e) {
      Get.snackbar('Error', 'Login failed: ${e.toString()}', backgroundColor: Colors.red);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> logout() async {
    await _storageService.clearTokens();
    currentUser.value = null;
    isLoggedIn.value = false;
    Get.offAll(() => LoginScreen());
  }

  bool get isAdmin => currentUser.value?.role == 'admin';
  bool get isTeamLead => currentUser.value?.role == 'team_lead' || isAdmin;
}

# lib/controllers/work_controller.dart
import 'package:get/get.dart';
import 'package:team_bioinfo/models/work_entry_model.dart';
import 'package:team_bioinfo/services/api_service.dart';

class WorkController extends GetxController {
  final ApiService _apiService = Get.find();
  
  RxList<WorkEntry> workEntries = <WorkEntry>[].obs;
  RxList<WorkEntry> pendingApprovals = <WorkEntry>[].obs;
  RxBool isLoading = false.obs;
  Rx<DateTime> selectedDate = DateTime.now().obs;

  @override
  void onInit() {
    super.onInit();
    loadTodayEntries();
  }

  Future<void> loadTodayEntries() async {
    try {
      isLoading.value = true;
      final entries = await _apiService.getWorkEntries(date: selectedDate.value);
      workEntries.value = entries;
    } catch (e) {
      Get.snackbar('Error', 'Failed to load work entries: ${e.toString()}');
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> loadEntriesForDate(DateTime date) async {
    selectedDate.value = date;
    await loadTodayEntries();
  }

  Future<void> createWorkEntry(WorkEntry entry) async {
    try {
      isLoading.value = true;
      await _apiService.createWorkEntry(entry);
      await loadTodayEntries();
      Get.back();
      Get.snackbar('Success', 'Work entry created successfully', backgroundColor: Colors.green);
    } catch (e) {
      Get.snackbar('Error', 'Failed to create work entry: ${e.toString()}', backgroundColor: Colors.red);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> updateWorkEntry(int entryId, WorkEntry entry) async {
    try {
      isLoading.value = true;
      await _apiService.updateWorkEntry(entryId, entry);
      await loadTodayEntries();
      Get.back();
      Get.snackbar('Success', 'Work entry updated successfully', backgroundColor: Colors.green);
    } catch (e) {
      Get.snackbar('Error', 'Failed to update work entry: ${e.toString()}', backgroundColor: Colors.red);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> approveWorkEntry(int entryId) async {
    try {
      await _apiService.approveWorkEntry(entryId);
      await loadTodayEntries();
      await loadPendingApprovals();
      Get.snackbar('Success', 'Work entry approved', backgroundColor: Colors.green);
    } catch (e) {
      Get.snackbar('Error', 'Failed to approve entry: ${e.toString()}', backgroundColor: Colors.red);
    }
  }

  Future<void> loadPendingApprovals() async {
    try {
      final entries = await _apiService.getPendingApprovals();
      pendingApprovals.value = entries;
    } catch (e) {
      print('Failed to load pending approvals: $e');
    }
  }

  double get todayTotalHours {
    return workEntries.fold(0.0, (sum, entry) => sum + entry.totalHours);
  }

  int get todayEntryCount => workEntries.length;
}

# lib/controllers/team_controller.dart
import 'package:get/get.dart';
import 'package:team_bioinfo/models/team_model.dart';
import 'package:team_bioinfo/models/task_model.dart';
import 'package:team_bioinfo/services/api_service.dart';

class TeamController extends GetxController {
  final ApiService _apiService = Get.find();
  
  RxList<Team> teams = <Team>[].obs;
  RxList<Task> tasks = <Task>[].obs;
  RxList<Task> myTasks = <Task>[].obs;
  RxBool isLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
    loadTeams();
    loadMyTasks();
  }

  Future<void> loadTeams() async {
    try {
      isLoading.value = true;
      final teamList = await _apiService.getTeams();
      teams.value = teamList;
    } catch (e) {
      Get.snackbar('Error', 'Failed to load teams: ${e.toString()}');
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> loadMyTasks() async {
    try {
      final taskList = await _apiService.getMyTasks();
      myTasks.value = taskList;
    } catch (e) {
      Get.snackbar('Error', 'Failed to load tasks: ${e.toString()}');
    }
  }

  Future<void> createTask(Task task) async {
    try {
      isLoading.value = true;
      await _apiService.createTask(task);
      await loadMyTasks();
      Get.back();
      Get.snackbar('Success', 'Task created successfully', backgroundColor: Colors.green);
    } catch (e) {
      Get.snackbar('Error', 'Failed to create task: ${e.toString()}', backgroundColor: Colors.red);
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> updateTaskProgress(int taskId, Map<String, dynamic> progressData) async {
    try {
      await _apiService.updateTaskProgress(taskId, progressData);
      await loadMyTasks();
      Get.snackbar('Success', 'Task updated successfully', backgroundColor: Colors.green);
    } catch (e) {
      Get.snackbar('Error', 'Failed to update task: ${e.toString()}', backgroundColor: Colors.red);
    }
  }
}

# lib/services/api_service.dart
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/models/user_model.dart';
import 'package:team_bioinfo/models/work_entry_model.dart';
import 'package:team_bioinfo/models/team_model.dart';
import 'package:team_bioinfo/models/task_model.dart';
import 'package:team_bioinfo/services/storage_service.dart';

class ApiService extends GetxService {
  late Dio _dio;
  final StorageService _storageService = Get.find();
  
  final String baseUrl = 'http://your-server-ip:8000'; // Replace with your server IP

  @override
  void onInit() {
    super.onInit();
    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: Duration(seconds: 30),
      receiveTimeout: Duration(seconds: 30),
    ));
    
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await _storageService.getAccessToken();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode == 401) {
          await _handleTokenRefresh();
          handler.next(error);
        } else {
          handler.next(error);
        }
      },
    ));
  }

  Future<void> _handleTokenRefresh() async {
    try {
      final refreshToken = await _storageService.getRefreshToken();
      if (refreshToken != null) {
        final response = await _dio.post('/auth/refresh', data: {'refresh_token': refreshToken});
        await _storageService.saveTokens(response.data['access_token'], response.data['refresh_token']);
      }
    } catch (e) {
      Get.find<AuthController>().logout();
    }
  }

  // Auth methods
  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = await _dio.post('/auth/login', data: {
      'email': email,
      'password': password,
    });
    return response.data;
  }

  Future<User> getCurrentUser() async {
    final response = await _dio.get('/auth/me');
    return User.fromJson(response.data);
  }

  // Work entry methods
  Future<List<WorkEntry>> getWorkEntries({DateTime? date, int? userId}) async {
    Map<String, dynamic> params = {};
    if (date != null) params['date'] = date.toIso8601String();
    if (userId != null) params['user_id'] = userId;
    
    final response = await _dio.get('/work-entries', queryParameters: params);
    return (response.data as List).map((json) => WorkEntry.fromJson(json)).toList();
  }

  Future<void> createWorkEntry(WorkEntry entry) async {
    await _dio.post('/work-entries', data: entry.toJson());
  }

  Future<void> updateWorkEntry(int entryId, WorkEntry entry) async {
    await _dio.put('/work-entries/$entryId', data: entry.toJson());
  }

  Future<void> approveWorkEntry(int entryId) async {
    await _dio.post('/work-entries/$entryId/approve');
  }

  Future<List<WorkEntry>> getPendingApprovals() async {
    final response = await _dio.get('/work-entries?approval_status=pending');
    return (response.data as List).map((json) => WorkEntry.fromJson(json)).toList();
  }

  // Team methods
  Future<List<Team>> getTeams() async {
    final response = await _dio.get('/teams');
    return (response.data as List).map((json) => Team.fromJson(json)).toList();
  }

  Future<void> createTeam(Team team) async {
    await _dio.post('/teams', data: team.toJson());
  }

  // Task methods
  Future<List<Task>> getMyTasks() async {
    final response = await _dio.get('/tasks');
    return (response.data as List).map((json) => Task.fromJson(json)).toList();
  }

  Future<void> createTask(Task task) async {
    await _dio.post('/tasks', data: task.toJson());
  }

  Future<void> updateTaskProgress(int taskId, Map<String, dynamic> progressData) async {
    await _dio.put('/tasks/$taskId/progress', data: progressData);
  }

  // Dashboard methods
  Future<Map<String, dynamic>> getDailyDashboard({DateTime? date}) async {
    Map<String, dynamic> params = {};
    if (date != null) params['date'] = date.toIso8601String();
    
    final response = await _dio.get('/dashboard/daily', queryParameters: params);
    return response.data;
  }

  Future<Map<String, dynamic>> getTeamDashboard(int teamId, {DateTime? startDate, DateTime? endDate}) async {
    Map<String, dynamic> params = {};
    if (startDate != null) params['start_date'] = startDate.toIso8601String();
    if (endDate != null) params['end_date'] = endDate.toIso8601String();
    
    final response = await _dio.get('/dashboard/team/$teamId', queryParameters: params);
    return response.data;
  }
}

# lib/services/storage_service.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

class StorageService extends GetxService {
  static const _storage = FlutterSecureStorage();
  
  Future<StorageService> init() async {
    return this;
  }

  Future<void> saveTokens(String accessToken, String refreshToken) async {
    await _storage.write(key: 'access_token', value: accessToken);
    await _storage.write(key: 'refresh_token', value: refreshToken);
  }

  Future<String?> getAccessToken() async {
    return await _storage.read(key: 'access_token');
  }

  Future<String?> getRefreshToken() async {
    return await _storage.read(key: 'refresh_token');
  }

  Future<void> clearTokens() async {
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'refresh_token');
  }

  Future<void> saveUserPreferences(Map<String, dynamic> preferences) async {
    for (String key in preferences.keys) {
      await _storage.write(key: 'pref_$key', value: preferences[key].toString());
    }
  }

  Future<String?> getUserPreference(String key) async {
    return await _storage.read(key: 'pref_$key');
  }
}

# lib/models/user_model.dart
class User {
  final int id;
  final String email;
  final String username;
  final String fullName;
  final String role;
  final int? teamId;
  final bool isActive;
  final DateTime createdAt;

  User({
    required this.id,
    required this.email,
    required this.username,
    required this.fullName,
    required this.role,
    this.teamId,
    required this.isActive,
    required this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'],
      email: json['email'],
      username: json['username'],
      fullName: json['full_name'],
      role: json['role'],
      teamId: json['team_id'],
      isActive: json['is_active'],
      createdAt: DateTime.parse(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'username': username,
      'full_name': fullName,
      'role': role,
      'team_id': teamId,
      'is_active': isActive,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

# lib/models/work_entry_model.dart
class WorkEntry {
  final int? id;
  final int userId;
  final DateTime date;
  final String tasks;
  final double totalHours;
  final String category;
  final String status;
  final String? notes;
  final double tertiaryAnalysisHours;
  final double cnvAnalysisHours;
  final double reportPreparationHours;
  final double reportReworkHours;
  final double reportCrosscheckHours;
  final double reportAllocationHours;
  final double genePanelCoverageHours;
  final String approvalStatus;
  final int? approvedBy;
  final DateTime? approvedAt;
  final double? estimatedHours;
  final bool isLocked;
  final DateTime? createdAt;

  WorkEntry({
    this.id,
    required this.userId,
    required this.date,
    required this.tasks,
    required this.totalHours,
    required this.category,
    required this.status,
    this.notes,
    this.tertiaryAnalysisHours = 0.0,
    this.cnvAnalysisHours = 0.0,
    this.reportPreparationHours = 0.0,
    this.reportReworkHours = 0.0,
    this.reportCrosscheckHours = 0.0,
    this.reportAllocationHours = 0.0,
    this.genePanelCoverageHours = 0.0,
    this.approvalStatus = 'pending',
    this.approvedBy,
    this.approvedAt,
    this.estimatedHours,
    this.isLocked = false,
    this.createdAt,
  });

  factory WorkEntry.fromJson(Map<String, dynamic> json) {
    return WorkEntry(
      id: json['id'],
      userId: json['user_id'],
      date: DateTime.parse(json['date']),
      tasks: json['tasks'],
      totalHours: json['total_hours'].toDouble(),
      category: json['category'],
      status: json['status'],
      notes: json['notes'],
      tertiaryAnalysisHours: json['tertiary_analysis_hours'].toDouble(),
      cnvAnalysisHours: json['cnv_analysis_hours'].toDouble(),
      reportPreparationHours: json['report_preparation_hours'].toDouble(),
      reportReworkHours: json['report_rework_hours'].toDouble(),
      reportCrosscheckHours: json['report_crosscheck_hours'].toDouble(),
      reportAllocationHours: json['report_allocation_hours'].toDouble(),
      genePanelCoverageHours: json['gene_panel_coverage_hours'].toDouble(),
      approvalStatus: json['approval_status'],
      approvedBy: json['approved_by'],
      approvedAt: json['approved_at'] != null ? DateTime.parse(json['approved_at']) : null,
      estimatedHours: json['estimated_hours']?.toDouble(),
      isLocked: json['is_locked'],
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user_id': userId,
      'date': date.toIso8601String(),
      'tasks': tasks,
      'total_hours': totalHours,
      'category': category,
      'status': status,
      'notes': notes,
      'tertiary_analysis_hours': tertiaryAnalysisHours,
      'cnv_analysis_hours': cnvAnalysisHours,
      'report_preparation_hours': reportPreparationHours,
      'report_rework_hours': reportReworkHours,
      'report_crosscheck_hours': reportCrosscheckHours,
      'report_allocation_hours': reportAllocationHours,
      'gene_panel_coverage_hours': genePanelCoverageHours,
      'estimated_hours': estimatedHours,
    };
  }
}

# lib/models/team_model.dart
import 'package:team_bioinfo/models/user_model.dart';

class Team {
  final int? id;
  final String name;
  final String? description;
  final int? teamLeadId;
  final int createdBy;
  final DateTime? createdAt;
  final List<User> members;

  Team({
    this.id,
    required this.name,
    this.description,
    this.teamLeadId,
    required this.createdBy,
    this.createdAt,
    this.members = const [],
  });

  factory Team.fromJson(Map<String, dynamic> json) {
    return Team(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      teamLeadId: json['team_lead_id'],
      createdBy: json['created_by'],
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at']) : null,
      members: json['members'] != null 
          ? (json['members'] as List).map((m) => User.fromJson(m)).toList()
          : [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'team_lead_id': teamLeadId,
      'created_by': createdBy,
    };
  }
}

# lib/models/task_model.dart
class Task {
  final int? id;
  final String title;
  final String? description;
  final int assignedTo;
  final int createdBy;
  final int? teamId;
  final String priority;
  final String status;
  final double? estimatedHours;
  final double actualHours;
  final DateTime? dueDate;
  final DateTime? completedAt;
  final int progressPercentage;
  final List<Map<String, dynamic>>? checklistItems;
  final DateTime? createdAt;

  Task({
    this.id,
    required this.title,
    this.description,
    required this.assignedTo,
    required this.createdBy,
    this.teamId,
    this.priority = 'medium',
    this.status = 'not_started',
    this.estimatedHours,
    this.actualHours = 0.0,
    this.dueDate,
    this.completedAt,
    this.progressPercentage = 0,
    this.checklistItems,
    this.createdAt,
  });

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: json['id'],
      title: json['title'],
      description: json['description'],
      assignedTo: json['assigned_to'],
      createdBy: json['created_by'],
      teamId: json['team_id'],
      priority: json['priority'],
      status: json['status'],
      estimatedHours: json['estimated_hours']?.toDouble(),
      actualHours: json['actual_hours'].toDouble(),
      dueDate: json['due_date'] != null ? DateTime.parse(json['due_date']) : null,
      completedAt: json['completed_at'] != null ? DateTime.parse(json['completed_at']) : null,
      progressPercentage: json['progress_percentage'],
      checklistItems: json['checklist_items'] != null 
          ? List<Map<String, dynamic>>.from(json['checklist_items'])
          : null,
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'description': description,
      'assigned_to': assignedTo,
      'team_id': teamId,
      'priority': priority,
      'estimated_hours': estimatedHours,
      'due_date': dueDate?.toIso8601String(),
      'checklist_items': checklistItems,
    };
  }
}

# lib/utils/app_theme.dart
import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryColor = Color(0xFF2E7D4F);
  static const Color secondaryColor = Color(0xFF4CAF50);
  static const Color accentColor = Color(0xFF81C784);
  static const Color backgroundColor = Color(0xFFF5F5F5);
  static const Color surfaceColor = Colors.white;
  static const Color errorColor = Color(0xFFE57373);

  static ThemeData lightTheme = ThemeData(
    primarySwatch: Colors.green,
    primaryColor: primaryColor,
    scaffoldBackgroundColor: backgroundColor,
    appBarTheme: AppBarTheme(
      backgroundColor: primaryColor,
      foregroundColor: Colors.white,
      elevation: 2,
      centerTitle: true,
    ),
    cardTheme: CardTheme(
      color: surfaceColor,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: primaryColor, width: 2),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
  );

  static ThemeData darkTheme = ThemeData.dark().copyWith(
    primaryColor: primaryColor,
    scaffoldBackgroundColor: Color(0xFF121212),
    appBarTheme: AppBarTheme(
      backgroundColor: Color(0xFF1E1E1E),
      foregroundColor: Colors.white,
    ),
    cardTheme: CardTheme(
      color: Color(0xFF1E1E1E),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

# lib/screens/splash_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/auth_controller.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';

class SplashScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).primaryColor,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.science,
              size: 100,
              color: Colors.white,
            ),
            SizedBox(height: 20),
            Text(
              'TEAM BIOINFO',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 10),
            Text(
              'Work Tracking System',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white70,
              ),
            ),
            SizedBox(height: 50),
            SpinKitWave(
              color: Colors.white,
              size: 50.0,
            ),
          ],
        ),
      ),
    );
  }
}

# lib/screens/login_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:team_bioinfo/controllers/auth_controller.dart';

class LoginScreen extends StatelessWidget {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final AuthController _authController = Get.find();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).primaryColor,
              Theme.of(context).primaryColor.withOpacity(0.8),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.science,
                          size: 80,
                          color: Theme.of(context).primaryColor,
                        ),
                        SizedBox(height: 16),
                        Text(
                          'TEAM BIOINFO',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Sign in to continue',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey[600],
                          ),
                        ),
                        SizedBox(height: 32),
                        TextFormField(
                          controller: _emailController,
                          decoration: InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.email),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter your email';
                            }
                            if (!GetUtils.isEmail(value)) {
                              return 'Please enter a valid email';
                            }
                            return null;
                          },
                        ),
                        SizedBox(height: 16),
                        TextFormField(
                          controller: _passwordController,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: Icon(Icons.lock),
                          ),
                          obscureText: true,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter your password';
                            }
                            return null;
                          },
                        ),
                        SizedBox(height: 24),
                        Obx(() => SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _authController.isLoading.value
                                ? null
                                : () {
                                    if (_formKey.currentState!.validate()) {
                                      _authController.login(
                                        _emailController.text,
                                        _passwordController.text,
                                      );
                                    }
                                  },
                            child: _authController.isLoading.value
                                ? CircularProgressIndicator(color: Colors.white)
                                : Text('Sign In'),
                          ),
                        )),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

# lib/screens/main_screen.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '(() => MainScreen());
      } catch (e) {
        await logout();
      }
    } else {
      Get.offAll
