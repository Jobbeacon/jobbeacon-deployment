# Chạy admin (và cụm service) ở local

Hướng dẫn chạy toàn bộ cụm để dev/test trang admin: `service-discovery` (Eureka) →
`Jobbeacon-gateway` → `Jobbeacon-be` → admin site của `Jobbeacon-fe`, cộng thêm
Prometheus/Loki/Grafana để xem monitoring.

Admin không còn tự xác thực Firebase nữa — **gateway** verify Firebase ID token rồi
forward header `X-User-*` xuống; backend chỉ đọc header, không verify gì cả (xem
`Jobbeacon-gateway/README.md`, phần "Auth flow").

## 1. Hạ tầng (Docker)

```bash
cd jobbeacon-deployment
docker compose up -d postgres rabbitmq redis elasticsearch crawler loki prometheus grafana node-exporter
```

Port mặc định (xem `.env`, đổi nếu trùng máy bạn): Postgres `5435`, RabbitMQ `5673`
(mgmt `15673`), Redis `6380`, Elasticsearch `9200`, Loki `3100`, Prometheus `9090`,
Grafana `3001` (user/pass `admin`/`admin`).

## 2. Build & chạy từng service Java (JDK 21 + Maven)

Chạy theo thứ tự, mỗi lệnh một terminal riêng:

```bash
# 1) service-discovery — Eureka, các service khác đăng ký vào đây
cd service-discovery && mvn spring-boot:run
# http://localhost:8761

# 2) Jobbeacon-be — profile "local" đọc jobbeacon-deployment/.env để trỏ đúng port Docker ở trên.
#    APP_ADMIN_EMAILS: email nào login lần đầu khớp danh sách này sẽ tự được gán role ADMIN.
cd Jobbeacon-be
APP_ADMIN_EMAILS=admin@jobbeacon.vn mvn spring-boot:run
# http://localhost:8080/jobbeacon-be

# 3) Jobbeacon-gateway — điểm vào public duy nhất, port 8088.
#    FIREBASE_PROJECT_ID phải khớp VITE_FIREBASE_PROJECT_ID của FE.
cd Jobbeacon-gateway
FIREBASE_PROJECT_ID=<project-id> \
CORS_ORIGINS=http://localhost:5173,http://localhost:5174 \
mvn spring-boot:run
# http://localhost:8088
```

Muốn log ứng dụng lên Grafana (panel "Log trực tiếp" của dashboard Hệ thống) thì
thêm `prod` vào profile, ví dụ: `PROFILE_ACTIVE=local,prod mvn spring-boot:run`
(giữ `local` để không mất override DB/port, chỉ bật thêm nhánh ghi Loki).

`jobbeacon-recommendation` và `Jobbeacon-sync` chạy tương tự (`mvn spring-boot:run`,
Eureka tự tìm thấy qua discovery) khi cần test luồng liên quan.

## 3. Admin site (Jobbeacon-fe)

`.env` (xem `.env.example`):

```bash
VITE_API_BASE_URL=http://localhost:8088/jobbeacon-be   # qua gateway, không gọi thẳng :8080
VITE_FIREBASE_API_KEY=...
VITE_FIREBASE_AUTH_DOMAIN=...
VITE_FIREBASE_PROJECT_ID=...                            # khớp FIREBASE_PROJECT_ID của gateway
VITE_FIREBASE_STORAGE_BUCKET=...
VITE_FIREBASE_MESSAGING_SENDER_ID=...
VITE_FIREBASE_APP_ID=...
VITE_GRAFANA_URL=http://localhost:3001                  # rỗng thì trang "Giám sát hệ thống" tự ẩn nội dung
```

```bash
npm install
npm run dev:admin   # http://localhost:5174
```

Đăng nhập bằng tài khoản Firebase thật (email/password hoặc Google) của project đã
cấu hình ở trên. Nếu email đó nằm trong `APP_ADMIN_EMAILS` khi backend start, lần
đăng nhập đầu sẽ tự tạo user và gán role ADMIN; nếu không, backend trả 403.

## 4. Xem monitoring

- Grafana: http://localhost:3001 (ẩn danh, chỉ xem) hoặc nhúng ngay trong admin site
  ở mục "Giám sát hệ thống".
- Dashboard "Hệ thống": trạng thái từng service, CPU/RAM/disk host, JVM heap, request
  rate/tỉ lệ lỗi/độ trễ (backend + gateway), log trực tiếp lọc theo service.
- Dashboard "Crawler": riêng cho job-posting-crawler (đã có từ trước).

**Giới hạn đã biết:** Prometheus (chạy trong Docker) gọi ra các service chạy trực
tiếp trên máy host qua `host.docker.internal`, IP này bị pin cứng trong
`docker-compose.yml` theo gateway thật của network `jobbeacon` trên máy đã test
(`172.26.0.1`). Máy khác có thể ra subnet khác — kiểm tra bằng:

```bash
docker network inspect jobbeacon_jobbeacon --format '{{json .IPAM.Config}}'
```

và sửa lại `extra_hosts` trong `docker-compose.yml` nếu khác. Về lâu dài, cách đúng
là container hóa `backend/gateway/discovery/recommendation/sync` vào chính
`docker-compose.yml` này (đã có Dockerfile ở từng repo) rồi scrape bằng tên service
y hệt `crawler` — bỏ hẳn `host.docker.internal`.

## 5. CI/CD — lưu ý trước khi merge

`Jobbeacon-be`, `Jobbeacon-gateway`, `service-discovery`, `jobbeacon-recommendation`
mỗi repo có `.github/workflows/ci-cd.yml`:

- **Pull request**: chỉ chạy `mvn test`. An toàn.
- **Push vào `main`**: chạy test → build Docker image → push lên GHCR → **SSH vào VM
  production và `docker compose up -d` service đó ngay lập tức.**

Tức là **merge vào `main` = tự động deploy lên production**, không có bước duyệt thủ
công nào khác ở giữa. Nhánh `feat/observability` tôi push cho từng repo (gateway,
discovery, recommendation, sync, be dùng nhánh `feat/admin-api` có sẵn) **chưa đụng
đến main**, mở PR thoải mái để xem CI chạy test — chỉ merge khi đã sẵn sàng để nó
lên production thật.

`Jobbeacon-fe` và `jobbeacon-deployment` hiện chưa thấy CI/CD tự động trong repo
(`jobbeacon-deployment` được VM kéo về thủ công hoặc qua cơ chế khác ngoài 2 repo
này — kiểm tra lại với người phụ trách VM trước khi merge
`feat/observability` của `jobbeacon-deployment`, vì thay đổi `docker-compose.yml`
ở đó — thêm `node-exporter`, bật anonymous Grafana — sẽ ảnh hưởng thật nếu VM dùng
đúng file này).
