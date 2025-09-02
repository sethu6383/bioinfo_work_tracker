if [[ $setup_ssl_choice =~ ^[Yy]$ ]]; then
        print_status "Setting up SSL certificates..."
        
        read -p "Enter your domain name (or 'localhost' for self-signed): " domain_name
        
        if [[ $domain_name == "localhost" ]]; then
            # Generate self-signed certificate
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout deployment/ssl/key.pem \
                -out deployment/ssl/cert.pem \
                -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"
            
            print_success "Self-signed SSL certificate generated"
        else
            print_status "For production, please place your SSL certificates as:"
            print_status "- Certificate: deployment/ssl/cert.pem"
            print_status "- Private Key: deployment/ssl/key.pem"
        fi
    fi
}

# Deploy backend services
deploy_backend() {
    print_status "Deploying backend services..."
    
    cd deployment
    
    # Stop any existing containers
    docker-compose down -v
    
    # Build and start services
    docker-compose build --no-cache
    docker-compose up -d
    
    # Wait for services to be ready
    print_status "Waiting for services to initialize..."
    sleep 15
    
    # Check if services are healthy
    for i in {1..30}; do
        if docker-compose exec postgres pg_isready -U bioinfo_user -d team_bioinfo_db >/dev/null 2>&1; then
            print_success "Database is ready"
            break
        fi
        if [ $i -eq 30 ]; then
            print_error "Database failed to start"
            exit 1
        fi
        sleep 2
    done
    
    # Initialize database
    print_status "Initializing database..."
    docker-compose exec api python -c "
from database import engine
from models import Base
Base.metadata.create_all(bind=engine)
print('Database initialized successfully!')
"
    
    cd ..
    print_success "Backend deployment completed"
}

# Create initial admin user
create_admin_user() {
    print_status "Creating initial admin user..."
    
    cd deployment
    
    # Interactive admin creation
    docker-compose exec -T api python << 'EOF'
import sys
from sqlalchemy.orm import Session
from database import SessionLocal
from models import User, UserRole
from auth import get_password_hash

def create_admin():
    db = SessionLocal()
    
    try:
        # Check if admin exists
        admin_exists = db.query(User).filter(User.role == UserRole.ADMIN).first()
        
        if admin_exists:
            print("Admin user already exists!")
            return
        
        # Create default admin
        admin_user = User(
            email="admin@teambioinfo.local",
            username="admin",
            full_name="System Administrator",
            hashed_password=get_password_hash("admin123"),
            role=UserRole.ADMIN,
            is_active=True
        )
        
        db.add(admin_user)
        db.commit()
        
        print("Default admin created!")
        print("Email: admin@teambioinfo.local")
        print("Password: admin123")
        print("⚠️  Please change this password immediately!")
        
    except Exception as e:
        print(f"Error creating admin: {e}")
        db.rollback()
    finally:
        db.close()

create_admin()
EOF
    
    cd ..
    print_success "Initial admin user created"
}

# Build mobile app
build_mobile_app() {
    if [[ $SKIP_MOBILE == true ]]; then
        print_warning "Skipping mobile app build (Flutter not installed)"
        return
    fi
    
    print_status "Building mobile application..."
    
    cd mobile
    
    # Get dependencies
    flutter pub get
    
    # Update API endpoint
    read -p "Enter your server IP address (default: localhost): " server_ip
    server_ip=${server_ip:-localhost}
    
    # Update API service with server IP
    sed -i "s/localhost:8000/${server_ip}:8000/g" lib/services/api_service.dart
    
    # Build Android APK
    print_status "Building Android APK..."
    flutter build apk --release
    
    # Create distribution directory
    mkdir -p ../dist/android
    cp build/app/outputs/flutter-apk/app-release.apk ../dist/android/team-bioinfo-${server_ip}.apk
    
    # Build iOS if on macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        print_status "Building iOS app..."
        flutter build ios --release
        
        mkdir -p ../dist/ios
        # Note: IPA creation requires Xcode signing
        print_status "iOS build completed. Use Xcode to create signed IPA."
    fi
    
    cd ..
    print_success "Mobile app build completed"
    print_success "Android APK: dist/android/team-bioinfo-${server_ip}.apk"
}

# Run tests
run_tests() {
    print_status "Running test suite..."
    
    cd deployment
    
    # Backend API tests
    print_status "Running backend tests..."
    docker-compose exec api python -m pytest tests/ -v
    
    # Load testing
    print_status "Running load tests..."
    docker-compose exec api python testing/load_test.py
    
    cd ..
    
    if [[ $SKIP_MOBILE == false ]]; then
        # Mobile tests
        print_status "Running mobile tests..."
        cd mobile
        flutter test
        cd ..
    fi
    
    print_success "Test suite completed"
}

# System verification
verify_deployment() {
    print_status "Verifying deployment..."
    
    # Check API health
    for i in {1..10}; do
        if curl -s http://localhost:8000/health >/dev/null 2>&1; then
            print_success "API is responding"
            break
        fi
        if [ $i -eq 10 ]; then
            print_error "API health check failed"
            return 1
        fi
        sleep 3
    done
    
    # Check database connection
    cd deployment
    if docker-compose exec postgres pg_isready -U bioinfo_user -d team_bioinfo_db >/dev/null 2>&1; then
        print_success "Database is accessible"
    else
        print_error "Database connection failed"
        return 1
    fi
    
    # Check Redis
    if docker-compose exec redis redis-cli ping >/dev/null 2>&1; then
        print_success "Redis is responding"
    else
        print_warning "Redis connection issue"
    fi
    
    cd ..
    print_success "Deployment verification completed"
}

# Generate documentation
generate_docs() {
    print_status "Generating system documentation..."
    
    mkdir -p docs
    
    # API documentation
    cat > docs/API_DOCUMENTATION.md << 'EOF'
# TEAM BIOINFO API Documentation

## Base URL
```
http://your-server-ip:8000
```

## Authentication
All protected endpoints require Bearer token in Authorization header:
```
Authorization: Bearer <access_token>
```

## Endpoints

### Authentication
- `POST /auth/login` - User login
- `POST /auth/register` - User registration  
- `POST /auth/refresh` - Refresh access token

### Work Management
- `GET /work-entries` - List work entries
- `POST /work-entries` - Create work entry
- `PUT /work-entries/{id}` - Update work entry
- `POST /work-entries/{id}/approve` - Approve entry

### Team Management
- `GET /teams` - List teams
- `POST /teams` - Create team
- `PUT /teams/{id}/members` - Update team members

### Task Management
- `GET /tasks` - List tasks
- `POST /tasks` - Create task
- `PUT /tasks/{id}/progress` - Update progress

### Analytics
- `GET /dashboard/daily` - Daily dashboard
- `GET /dashboard/team/{id}` - Team dashboard
- `GET /dashboard/performance` - Performance metrics

### Admin Functions
- `GET /users` - List users (Admin only)
- `PUT /users/{id}/role` - Update user role (Admin only)
- `GET /reports/export` - Export data (Admin only)
- `GET /backup/daily` - Create backup (Admin only)

## Data Models

### Work Entry
```json
{
  "date": "2024-01-15T00:00:00",
  "tasks": "Analysis work description",
  "total_hours": 8.0,
  "category": "Analysis",
  "status": "completed",
  "notes": "Optional notes",
  "tertiary_analysis_hours": 4.0,
  "cnv_analysis_hours": 2.0,
  "report_preparation_hours": 2.0,
  "estimated_hours": 8.0
}
```

### Task
```json
{
  "title": "Task title",
  "description": "Task description",
  "assigned_to": 1,
  "priority": "high",
  "estimated_hours": 4.0,
  "due_date": "2024-01-20T00:00:00",
  "checklist_items": [
    {"item": "Step 1", "completed": false},
    {"item": "Step 2", "completed": true}
  ]
}
```
EOF

    # User manual
    cat > docs/USER_MANUAL.md << 'EOF'
# TEAM BIOINFO User Manual

## Getting Started

### First Login
1. Install the Team Bioinfo app on your device
2. Open the app and login with your credentials
3. Complete your profile setup

### Daily Work Entry
1. Tap "Add Entry" on the dashboard
2. Fill in your work details:
   - Tasks performed
   - Category selection
   - Hours breakdown by analysis type
3. Submit for approval

### Task Management
1. View assigned tasks in the Tasks tab
2. Update progress using the slider
3. Check off completed checklist items
4. Add actual hours worked

### Team Features (Team Leads)
1. Access Team tab for team overview
2. Create and assign new tasks
3. Monitor team performance
4. Approve team member entries

### Admin Features
1. Access Admin panel for system overview
2. Manage users and teams
3. Approve work entries
4. Export data and create backups
5. View system analytics

## Tips for Best Results
- Submit work entries daily for accurate tracking
- Use detailed task descriptions
- Update task progress regularly
- Review team dashboards weekly
EOF

    # Troubleshooting guide
    cat > docs/TROUBLESHOOTING.md << 'EOF'
# TEAM BIOINFO Troubleshooting Guide

## Common Issues

### Mobile App Issues

**Problem**: App won't connect to server
**Solution**: 
1. Check server IP in app settings
2. Verify server is running: `./monitor.sh`
3. Check network connectivity

**Problem**: Login fails
**Solution**:
1. Verify credentials
2. Check if account is active
3. Contact admin if account is locked

**Problem**: Work entry won't save
**Solution**:
1. Check if entry already exists for the date
2. Verify all required fields are filled
3. Ensure hours don't exceed 24

### Server Issues

**Problem**: API not responding
**Solution**:
```bash
docker-compose logs api
docker-compose restart api
```

**Problem**: Database connection failed
**Solution**:
```bash
docker-compose logs postgres
docker-compose restart postgres
```

**Problem**: Out of disk space
**Solution**:
1. Check disk usage: `df -h`
2. Clean old backups: `find backups/ -mtime +730 -delete`
3. Clean old exports: `find exports/ -mtime +30 -delete`

### Performance Issues

**Problem**: Slow response times
**Solution**:
1. Check system resources: `top`
2. Monitor database: `docker-compose exec postgres pg_stat_activity`
3. Check Redis: `docker-compose exec redis redis-cli info`

**Problem**: High memory usage
**Solution**:
1. Restart services: `docker-compose restart`
2. Check for memory leaks in logs
3. Consider increasing server resources
EOF

    print_success "Documentation generated in docs/ directory"
}

# Load testing script
create_load_test() {
    cat > testing/load_test.py << 'EOF'
#!/usr/bin/env python3

import asyncio
import aiohttp
import time
import json
import random
from datetime import datetime, timedelta

class LoadTester:
    def __init__(self, base_url="http://localhost:8000", concurrent_users=20):
        self.base_url = base_url
        self.concurrent_users = concurrent_users
        self.test_users = []
        self.results = {
            "total_requests": 0,
            "successful_requests": 0,
            "failed_requests": 0,
            "avg_response_time": 0,
            "errors": []
        }

    async def create_test_user(self, session, user_id):
        """Create a test user for load testing"""
        user_data = {
            "email": f"loadtest{user_id}@example.com",
            "username": f"loadtest{user_id}",
            "full_name": f"Load Test User {user_id}",
            "password": "testpass123"
        }
        
        try:
            async with session.post(f"{self.base_url}/auth/register", json=user_data) as resp:
                if resp.status == 200:
                    return await resp.json()
        except Exception as e:
            print(f"Error creating user {user_id}: {e}")
        return None

    async def login_user(self, session, email, password):
        """Login and get access token"""
        login_data = {"email": email, "password": password}
        
        try:
            async with session.post(f"{self.base_url}/auth/login", json=login_data) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return data["access_token"]
        except Exception as e:
            print(f"Login error: {e}")
        return None

    async def simulate_user_activity(self, session, user_id):
        """Simulate typical user activity"""
        # Create user and login
        user = await self.create_test_user(session, user_id)
        if not user:
            return

        token = await self.login_user(session, user["email"], "testpass123")
        if not token:
            return

        headers = {"Authorization": f"Bearer {token}"}
        
        # Simulate work entry creation
        for day in range(5):  # 5 days of entries
            work_entry = {
                "date": (datetime.now() - timedelta(days=day)).isoformat(),
                "tasks": f"Sample work for day {day}",
                "total_hours": random.uniform(6, 9),
                "category": random.choice(["Analysis", "Report Generation", "Quality Control"]),
                "status": "completed",
                "tertiary_analysis_hours": random.uniform(2, 4),
                "cnv_analysis_hours": random.uniform(1, 3),
                "report_preparation_hours": random.uniform(1, 2)
            }
            
            start_time = time.time()
            try:
                async with session.post(f"{self.base_url}/work-entries", 
                                      json=work_entry, headers=headers) as resp:
                    end_time = time.time()
                    response_time = end_time - start_time
                    
                    self.results["total_requests"] += 1
                    
                    if resp.status == 200:
                        self.results["successful_requests"] += 1
                    else:
                        self.results["failed_requests"] += 1
                        self.results["errors"].append(f"Status {resp.status}: {await resp.text()}")
                    
                    # Update average response time
                    total_responses = self.results["successful_requests"] + self.results["failed_requests"]
                    self.results["avg_response_time"] = (
                        (self.results["avg_response_time"] * (total_responses - 1) + response_time) / total_responses
                    )
            
            except Exception as e:
                self.results["failed_requests"] += 1
                self.results["errors"].append(str(e))
            
            await asyncio.sleep(0.1)  # Small delay between requests

        # Simulate dashboard access
        try:
            async with session.get(f"{self.base_url}/dashboard/daily", headers=headers) as resp:
                self.results["total_requests"] += 1
                if resp.status == 200:
                    self.results["successful_requests"] += 1
                else:
                    self.results["failed_requests"] += 1
        except Exception as e:
            self.results["failed_requests"] += 1
            self.results["errors"].append(str(e))

    async def run_load_test(self):
        """Run the complete load test"""
        print(f"Starting load test with {self.concurrent_users} concurrent users...")
        
        connector = aiohttp.TCPConnector(limit=100, limit_per_host=50)
        timeout = aiohttp.ClientTimeout(total=30)
        
        async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
            # Create tasks for concurrent users
            tasks = []
            for i in range(self.concurrent_users):
                task = asyncio.create_task(self.simulate_user_activity(session, i))
                tasks.append(task)
            
            start_time = time.time()
            await asyncio.gather(*tasks)
            end_time = time.time()
            
            total_time = end_time - start_time
            
            # Print results
            print("\n" + "="*50)
            print("LOAD TEST RESULTS")
            print("="*50)
            print(f"Concurrent Users: {self.concurrent_users}")
            print(f"Total Test Time: {total_time:.2f} seconds")
            print(f"Total Requests: {self.results['total_requests']}")
            print(f"Successful Requests: {self.results['successful_requests']}")
            print(f"Failed Requests: {self.results['failed_requests']}")
            print(f"Success Rate: {(self.results['successful_requests']/self.results['total_requests']*100):.1f}%")
            print(f"Average Response Time: {self.results['avg_response_time']:.3f} seconds")
            print(f"Requests per Second: {self.results['total_requests']/total_time:.1f}")
            
            if self.results['errors']:
                print(f"\nErrors ({len(self.results['errors'])}):")
                for error in self.results['errors'][:5]:  # Show first 5 errors
                    print(f"  - {error}")
                if len(self.results['errors']) > 5:
                    print(f"  ... and {len(self.results['errors']) - 5} more")

if __name__ == "__main__":
    import sys
    
    concurrent_users = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    base_url = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:8000"
    
    tester = LoadTester(base_url, concurrent_users)
    asyncio.run(tester.run_load_test())
EOF

    chmod +x testing/load_test.py
}

# Create monitoring tools
create_monitoring() {
    cat > deployment/monitor.sh << 'EOF'
#!/bin/bash

echo "🔍 TEAM BIOINFO System Monitor"
echo "============================="

# System overview
echo "📊 System Overview"
echo "Container Status:"
docker-compose ps

echo -e "\n💾 Storage Usage:"
df -h | head -1
df -h | grep -E "(backups|exports)" || echo "Backup/Export volumes not mounted"

echo -e "\n🗄️  Database Status:"
if docker-compose exec postgres pg_isready -U bioinfo_user -d team_bioinfo_db >/dev/null 2>&1; then
    echo "✅ Database: Healthy"
    
    # Database size
    db_size=$(docker-compose exec postgres psql -U bioinfo_user -d team_bioinfo_db -t -c "
        SELECT pg_size_pretty(pg_database_size('team_bioinfo_db'));
    " | xargs)
    echo "   Size: $db_size"
    
    # Table counts
    echo "   Records:"
    docker-compose exec postgres psql -U bioinfo_user -d team_bioinfo_db -t -c "
        SELECT 'Users: ' || COUNT(*) FROM users;
        SELECT 'Teams: ' || COUNT(*) FROM teams;
        SELECT 'Work Entries: ' || COUNT(*) FROM work_entries;
        SELECT 'Tasks: ' || COUNT(*) FROM tasks;
    " | sed 's/^ */   /'
else
    echo "❌ Database: Unhealthy"
fi

echo -e "\n🔄 Redis Status:"
if docker-compose exec redis redis-cli ping >/dev/null 2>&1; then
    echo "✅ Redis: Healthy"
    redis_memory=$(docker-compose exec redis redis-cli info memory | grep used_memory_human | cut -d: -f2 | tr -d '\r')
    echo "   Memory: $redis_memory"
else
    echo "❌ Redis: Unhealthy"
fi

echo -e "\n🌐 API Status:"
api_health=$(curl -s http://localhost:8000/health 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "✅ API: Healthy"
    echo "   Response: $api_health"
else
    echo "❌ API: Unhealthy"
fi

echo -e "\n📁 Recent Backups:"
ls -la backups/ | tail -5

echo -e "\n📄 Recent Exports:"
ls -la exports/ | tail -5

echo -e "\n📝 Recent API Logs:"
docker-compose logs --tail=5 api

echo -e "\n🚨 System Alerts:"
# Check for issues
issues=0

# Check disk space
disk_usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
if [ $disk_usage -gt 90 ]; then
    echo "⚠️  High disk usage: ${disk_usage}%"
    ((issues++))
fi

# Check memory usage
memory_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100}')
if [ $memory_usage -gt 90 ]; then
    echo "⚠️  High memory usage: ${memory_usage}%"
    ((issues++))
fi

# Check failed containers
failed_containers=$(docker-compose ps | grep -c "Exit")
if [ $failed_containers -gt 0 ]; then
    echo "⚠️  Failed containers detected: $failed_containers"
    ((issues++))
fi

if [ $issues -eq 0 ]; then
    echo "✅ No issues detected"
fi

echo -e "\n📈 Performance Metrics:"
echo "   Uptime: $(uptime -p)"
echo "   Load Average: $(uptime | awk -F'load average:' '{print $2}')"
echo "   Available Memory: $(free -h | grep Mem | awk '{print $7}')"
EOF

    chmod +x deployment/monitor.sh
}

# Create maintenance scripts
create_maintenance_scripts() {
    # Backup cleanup script
    cat > deployment/cleanup_backups.sh << 'EOF'
#!/bin/bash

echo "🧹 Cleaning up old backups..."

# Remove backups older than 2 years
find backups/ -name "*.json" -mtime +730 -exec rm -f {} \;

# Remove exports older than 30 days
find exports/ -name "*" -mtime +30 -exec rm -f {} \;

# Compress old backups (older than 30 days)
find backups/ -name "*.json" -mtime +30 ! -name "*.gz" -exec gzip {} \;

echo "Cleanup completed"
EOF

    # Database maintenance script
    cat > deployment/db_maintenance.sh << 'EOF'
#!/bin/bash

echo "🔧 Database maintenance..."

docker-compose exec postgres psql -U bioinfo_user -d team_bioinfo_db << 'SQL'
-- Vacuum and analyze tables
VACUUM ANALYZE;

-- Reindex tables
REINDEX DATABASE team_bioinfo_db;

-- Show table sizes
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables 
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
SQL

echo "Database maintenance completed"
EOF

    # System update script
    cat > deployment/update_system.sh << 'EOF'
#!/bin/bash

echo "🔄 Updating TEAM BIOINFO system..."

# Create backup before update
./monitor.sh > "update_backup_$(date +%Y%m%d_%H%M%S).log"

# Pull latest images
docker-compose pull

# Rebuild with latest code
docker-compose build --no-cache

# Restart services with zero downtime
docker-compose up -d --force-recreate

# Wait for services to be ready
sleep 30

# Verify deployment
echo "Verifying updated deployment..."
curl -s http://localhost:8000/health

echo "Update completed!"
EOF

    chmod +x deployment/*.sh
}

# Main setup function
main() {
    echo "Starting TEAM BIOINFO complete setup..."
    echo "This will set up the entire work tracking system."
    echo ""
    
    read -p "Continue with setup? (y/N): " continue_setup
    if [[ ! $continue_setup =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
    
    check_requirements
    setup_directories
    generate_configs
    setup_ssl
    
    print_status "Creating deployment files..."
    create_load_test
    create_monitoring
    create_maintenance_scripts
    
    deploy_backend
    create_admin_user
    
    if [[ $SKIP_MOBILE == false ]]; then
        build_mobile_app
    fi
    
    verify_deployment
    generate_docs
    
    echo ""
    echo "🎉 TEAM BIOINFO Setup Completed Successfully!"
    echo "=========================================="
    echo ""
    echo "📱 Mobile App:"
    if [[ $SKIP_MOBILE == false ]]; then
        echo "   Android APK: dist/android/team-bioinfo-*.apk"
        echo "   Install: adb install dist/android/team-bioinfo-*.apk"
    else
        echo "   ⚠️  Flutter not installed - mobile app build skipped"
    fi
    echo ""
    echo "🌐 Web Access:"
    echo "   API: http://localhost:8000"
    echo "   Health: http://localhost:8000/health"
    echo "   API Docs: http://localhost:8000/docs"
    echo ""
    echo "🔑 Default Admin Credentials:"
    echo "   Email: admin@teambioinfo.local"
    echo "   Password: admin123"
    echo "   ⚠️  CHANGE THESE IMMEDIATELY!"
    echo ""
    echo "🛠️  Management Commands:"
    echo "   Monitor: ./deployment/monitor.sh"
    echo "   Backup: docker-compose exec api python backup_scheduler.py"
    echo "   Logs: docker-compose logs -f api"
    echo ""
    echo "📚 Documentation:"
    echo "   User Manual: docs/USER_MANUAL.md"
    echo "   API Docs: docs/API_DOCUMENTATION.md"
    echo "   Troubleshooting: docs/TROUBLESHOOTING.md"
    echo ""
    echo "🔧 Next Steps:"
    echo "1. Change default admin password"
    echo "2. Create your team structure"
    echo "3. Add team members"
    echo "4. Install mobile app on team devices"
    echo "5. Configure SSL for production use"
    echo ""
    echo "✅ System is ready for use!"
}

# Error handling
trap 'print_error "Setup failed at line $LINENO"' ERR

# Run main setup
main "$@"

# testing/mobile_e2e_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:team_bioinfo/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('TEAM BIOINFO E2E Tests', () {
    testWidgets('Complete user workflow test', (WidgetTester tester) async {
      app.main();
      await tester.pumpAndSettle();

      // Create new task
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(Key('task_title')), 'E2E Test Task');
      await tester.enterText(find.byKey(Key('task_description')), 'Test task for E2E testing');
      await tester.tap(find.byKey(Key('create_task_button')));
      await tester.pumpAndSettle(Duration(seconds: 3));

      // Verify task was created
      expect(find.text('E2E Test Task'), findsOneWidget);

      // Test task progress update
      await tester.tap(find.text('Update Progress'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(Key('progress_slider')));
      await tester.tap(find.byKey(Key('save_progress')));
      await tester.pumpAndSettle();
    });

    testWidgets('Data validation tests', (WidgetTester tester) async {
      app.main();
      await tester.pumpAndSettle();

      // Login
      await tester.enterText(find.byKey(Key('email_field')), 'admin@teambioinfo.local');
      await tester.enterText(find.byKey(Key('password_field')), 'admin123');
      await tester.tap(find.byKey(Key('login_button')));
      await tester.pumpAndSettle(Duration(seconds: 3));

      // Test invalid work entry (hours > 24)
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(Key('tasks_field')), 'Invalid hours test');
      await tester.enterText(find.byKey(Key('tertiary_hours')), '25'); // Invalid

      await tester.tap(find.byKey(Key('submit_button')));
      await tester.pumpAndSettle();

      // Should show validation error
      expect(find.text('Hours must be between 0 and 24'), findsOneWidget);
    });
  });
}

# Load Testing Configuration
# testing/load_test_config.yaml
load_test:
  concurrent_users: 20
  test_duration: 300  # 5 minutes
  ramp_up_time: 60    # 1 minute
  base_url: "http://localhost:8000"
  
scenarios:
  - name: "user_login"
    weight: 20
    actions:
      - login
      - view_dashboard
      
  - name: "work_entry_creation"
    weight: 40
    actions:
      - login
      - create_work_entry
      - view_work_entries
      
  - name: "task_management"
    weight: 25
    actions:
      - login
      - view_tasks
      - update_task_progress
      
  - name: "admin_operations"
    weight: 15
    actions:
      - admin_login
      - approve_entries
      - view_analytics

# Production Deployment Guide
# deployment/PRODUCTION_DEPLOYMENT.md

## Production Deployment Guide

### Pre-Deployment Checklist

1. **Server Requirements**
   - Minimum: 4 GB RAM, 2 CPU cores, 100 GB storage
   - Recommended: 8 GB RAM, 4 CPU cores, 500 GB storage
   - Operating System: Ubuntu 20.04+ or CentOS 8+

2. **Network Configuration**
   - Open ports: 80 (HTTP), 443 (HTTPS)
   - Internal ports: 5432 (PostgreSQL), 6379 (Redis), 8000 (API)
   - Configure firewall rules

3. **SSL Certificates**
   - Obtain SSL certificates from your CA
   - Place certificates in deployment/ssl/
   - Update nginx configuration

### Step-by-Step Deployment

1. **Server Preparation**
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

2. **Application Deployment**
```bash
# Clone repository
git clone <your-repo-url>
cd team-bioinfo

# Run complete setup
chmod +x deployment/complete_setup.sh
./deployment/complete_setup.sh
```

3. **SSL Configuration**
```bash
# Copy your SSL certificates
cp your-cert.pem deployment/ssl/cert.pem
cp your-key.pem deployment/ssl/key.pem

# Update nginx configuration to enable HTTPS
# Uncomment SSL server block in deployment/nginx/nginx.conf

# Restart nginx
docker-compose restart nginx
```

4. **Backup Configuration**
```bash
# Setup automated backups
crontab -e

# Add these lines:
0 2 * * * cd /path/to/team-bioinfo/deployment && docker-compose exec api python backup_scheduler.py daily
0 3 * * 0 cd /path/to/team-bioinfo/deployment && docker-compose exec api python backup_scheduler.py weekly
0 4 1 * * cd /path/to/team-bioinfo/deployment && docker-compose exec api python backup_scheduler.py monthly
```

5. **Monitoring Setup**
```bash
# Setup log rotation
sudo tee /etc/logrotate.d/team-bioinfo << EOF
/path/to/team-bioinfo/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF

# Setup monitoring cron
crontab -e
# Add: */5 * * * * /path/to/team-bioinfo/deployment/monitor.sh > /tmp/bioinfo-health.log
```

### Post-Deployment Configuration

1. **Initial Admin Setup**
```bash
# Create admin user
docker-compose exec api python create_admin.py

# Or use the default admin and change password via API
```

2. **Team Structure Setup**
```bash
# Use the admin panel or API to:
# - Create teams
# - Add team members
# - Assign team leads
# - Configure roles
```

3. **Mobile App Distribution**
```bash
# Build mobile app with production server IP
cd mobile
flutter build apk --release

# Distribute APK to team members
# For iOS: Build IPA and distribute via TestFlight
```

### Security Hardening

1. **Change Default Credentials**
   - Update admin password immediately
   - Generate new JWT secret key
   - Update database passwords

2. **Network Security**
   - Configure firewall rules
   - Use VPN for admin access
   - Enable fail2ban for brute force protection

3. **Application Security**
   - Enable HTTPS only
   - Configure CORS properly
   - Set up rate limiting
   - Regular security updates

### Backup Strategy

1. **Automated Backups**
   - Daily: Application data
   - Weekly: Complete system backup
   - Monthly: Archive backup

2. **Backup Storage**
   - Local: /app/backups/
   - Remote: Configure rsync to backup server
   - Cloud: Optional cloud backup integration

3. **Recovery Testing**
   - Test backup restoration monthly
   - Document recovery procedures
   - Train admin staff on recovery process

### Monitoring and Alerts

1. **System Monitoring**
```bash
# Setup monitoring dashboard
# Use the provided monitor.sh script
# Configure alerts for:
# - High disk usage (>90%)
# - High memory usage (>90%)
# - Failed containers
# - API downtime
```

2. **Performance Monitoring**
   - Monitor API response times
   - Track database performance
   - Watch for memory leaks
   - Monitor concurrent user limits

### Maintenance Schedule

**Daily**
- Check system health
- Review error logs
- Monitor disk space

**Weekly**
- Review performance metrics
- Check backup integrity
- Update system if needed

**Monthly**
- Database maintenance
- Security audit
- Backup cleanup
- Performance optimization

### Scaling Considerations

**Horizontal Scaling**
- Add more API containers behind load balancer
- Database read replicas for analytics
- Redis cluster for high availability

**Vertical Scaling**
- Increase server resources
- Optimize database queries
- Implement caching strategies

### Troubleshooting Production Issues

**High Load**
1. Check concurrent user count
2. Monitor database connections
3. Review slow query logs
4. Scale resources if needed

**Data Corruption**
1. Stop application immediately
2. Restore from latest backup
3. Investigate root cause
4. Implement additional validation

**Security Incident**
1. Isolate affected systems
2. Review audit logs
3. Reset compromised credentials
4. Apply security patches

### Support and Maintenance

**Regular Tasks**
- Monitor system health daily
- Review and rotate logs weekly
- Update dependencies monthly
- Security patches as needed

**Emergency Procedures**
- Data recovery from backups
- Service restoration steps
- Incident response protocol
- Team notification procedures

---

## Contact Information

**System Administrator**: [Your Name]
**Emergency Contact**: [Emergency Number]
**Technical Support**: [Support Email]

## Version Information

**System Version**: 1.0.0
**Last Updated**: $(date)
**Documentation Version**: 1.0.0

---

*This deployment guide covers production setup for the TEAM BIOINFO work tracking system. For development setup, refer to the main README.md file.* Test login flow
      await tester.enterText(find.byKey(Key('email_field')), 'admin@teambioinfo.local');
      await tester.enterText(find.byKey(Key('password_field')), 'admin123');
      await tester.tap(find.byKey(Key('login_button')));
      await tester.pumpAndSettle(Duration(seconds: 3));

      // Verify main screen loaded
      expect(find.text('TEAM BIOINFO'), findsOneWidget);
      expect(find.text('Dashboard'), findsOneWidget);

      // Test work entry creation
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(Key('tasks_field')), 'E2E test work entry');
      await tester.enterText(find.byKey(Key('tertiary_hours')), '4');
      await tester.enterText(find.byKey(Key('cnv_hours')), '2');
      await tester.enterText(find.byKey(Key('report_prep_hours')), '2');

      await tester.tap(find.byKey(Key('submit_button')));
      await tester.pumpAndSettle(Duration(seconds: 3));

      // Verify entry was created
      expect(find.text('E2E test work entry'), findsOneWidget);

      // Test navigation to other tabs
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
      expect(find.text('My Tasks'), findsOneWidget);

      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      expect(find.text('Teams'), findsOneWidget);

      await tester.tap(find.text('Admin'));
      await tester.pumpAndSettle();
      expect(find.text('Admin Panel'), findsOneWidget);
    });

    testWidgets('Task management workflow', (WidgetTester tester) async {
      app.main();
      await tester.pumpAndSettle();

      // Login as admin
      await tester.enterText(find.byKey(Key('email_field')), 'admin@teambioinfo.local');
      await tester.enterText(find.byKey(Key('password_field')), 'admin123');
      await tester.tap(find.byKey(Key('login_button')));
      await tester.pumpAndSettle(Duration(seconds: 3));

      // Navigate to tasks
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();

      //# Complete Deployment Package

# deployment/complete_setup.sh
#!/bin/bash

set -e

echo "🚀 TEAM BIOINFO Complete Setup Script"
echo "===================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check requirements
check_requirements() {
    print_status "Checking system requirements..."
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        print_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi
    
    if ! command -v flutter &> /dev/null; then
        print_warning "Flutter is not installed. Mobile app build will be skipped."
        SKIP_MOBILE=true
    else
        SKIP_MOBILE=false
    fi
    
    print_success "Requirements check completed"
}

# Create directory structure
setup_directories() {
    print_status "Creating directory structure..."
    
    mkdir -p {backend,mobile,deployment,testing,docs}
    mkdir -p deployment/{nginx,ssl,scripts}
    mkdir -p backend/{app,tests}
    mkdir -p {backups,exports,logs}/{daily,weekly,monthly}
    mkdir -p mobile/{lib,android,ios}
    
    # Set proper permissions
    chmod 755 backups exports logs
    chmod 700 deployment/ssl
    
    print_success "Directory structure created"
}

# Generate secure configurations
generate_configs() {
    print_status "Generating secure configurations..."
    
    # Generate JWT secret
    JWT_SECRET=$(openssl rand -hex 32)
    
    # Generate database password
    DB_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-16)
    
    # Create .env file
    cat > deployment/.env << EOF
# Database Configuration
POSTGRES_DB=team_bioinfo_db
POSTGRES_USER=bioinfo_user
POSTGRES_PASSWORD=${DB_PASSWORD}
DATABASE_URL=postgresql://bioinfo_user:${DB_PASSWORD}@postgres:5432/team_bioinfo_db

# JWT Configuration
SECRET_KEY=${JWT_SECRET}
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
API_RATE_LIMIT=100
AUTH_RATE_LIMIT=10

# Paths
EXPORT_PATH=/app/exports
BACKUP_PATH=/app/backups
LOG_PATH=/app/logs

# Security
CORS_ORIGINS=["http://localhost:3000","https://localhost:3000"]
TRUSTED_HOSTS=["localhost","127.0.0.1"]

# Monitoring
HEALTH_CHECK_INTERVAL=30
LOG_LEVEL=INFO
EOF

    print_success "Secure configurations generated"
    print_warning "Database password: ${DB_PASSWORD}"
    print_warning "Please save these credentials securely!"
}

# Setup SSL (optional)
setup_ssl() {
    read -p "Do you want to setup SSL certificates? (y/N): " setup_ssl_choice
    
    if [[ $setup_ssl_choice =~ ^[Yy]
