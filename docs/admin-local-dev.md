# Chạy admin (và cụm service) ở local

Production đã container hóa toàn bộ cụm qua `compose.apps.yml` (discovery, backend,
gateway, crawler, sync, recommendation, frontend — xem file đó để biết env var chính
xác của từng service). Hướng dẫn dưới đây là cho **dev lặp nhanh trên máy cá nhân**:
chạy service Java trực tiếp bằng `mvn spring-boot:run` (không build lại Docker image
mỗi lần sửa code), chỉ Postgres/RabbitMQ/Redis/Elasticsearch/Loki/Prometheus/Grafana
chạy qua Docker.

Admin không tự xác thực Firebase — **gateway** verify Firebase ID token rồi forward
header `X-User-*` xuống; backend chỉ đọc header (xem `Jobbeacon-gateway/README.md`,
phần "Auth flow").

## 1. Hạ tầng + observability (Docker)

```bash
cd jobbeacon-deployment
docker compose up -d postgres rabbitmq redis elasticsearch crawler loki prometheus grafana node-exporter
```

Port mặc định (xem `.env`, đổi nếu trùng máy bạn): Postgres `5435`, RabbitMQ `5673`
(mgmt `15673`), Redis `6380`, Elasticsearch `9200`, Loki `3100`, Prometheus `9090`,
Grafana `3001` (user/pass `admin`/`admin`). Tất cả port này chỉ bind `127.0.0.1` —
đúng với quy ước của file, không đổi thành public.

## 2. Build & chạy từng service Java (JDK 21 + Maven) ngoài Docker

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
thêm `prod` vào profile, ví dụ `PROFILE_ACTIVE=local,prod mvn spring-boot:run` (giữ
`local` để không mất override DB/port, chỉ bật thêm nhánh ghi Loki). Service chạy
kiểu này phải truyền thêm `LOKI_URL=http://localhost:3100/loki/api/v1/push` nếu bạn
đổi port Loki khác mặc định — giá trị mặc định trong code đã là localhost.

`jobbeacon-recommendation` và `Jobbeacon-sync` chạy tương tự khi cần test luồng liên
quan.

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

Production chưa có service nào build/deploy bản admin của FE (`compose.apps.yml` chỉ
có 1 service `frontend`, build Dockerfile mặc định — không phải
`--build-arg APP_TARGET=admin`). Muốn đưa admin lên production thì cần thêm service
mới cho bản build đó trước.

## 4. Xem monitoring

- Grafana: http://localhost:3001 (ẩn danh, chỉ xem) hoặc nhúng ngay trong admin site
  ở mục "Giám sát hệ thống".
- Dashboard "Hệ thống": trạng thái từng service, CPU/RAM/disk host, JVM heap, request
  rate/tỉ lệ lỗi/độ trễ (backend + gateway), load average, log trực tiếp lọc theo
  service.
- Dashboard "Crawler": riêng cho job-posting-crawler (đã có từ trước).

**Giới hạn khi chạy kiểu này:** Prometheus (trong Docker) gọi ra các service bạn
chạy trực tiếp trên máy qua `host.docker.internal` (chuẩn Docker, map tới gateway
của network). Nếu nó không resolve đúng trên máy bạn, kiểm tra gateway thật của
network bằng:

```bash
docker network inspect jobbeacon_jobbeacon --format '{{json .IPAM.Config}}'
```

và so với kết quả `getent hosts host.docker.internal` chạy trong container Prometheus
(`docker exec jobbeacon-prometheus cat /etc/hosts`). Khi `backend/gateway/discovery/
recommendation/sync` cũng chạy qua Docker (giống cách production làm, xem
`compose.apps.yml`) thì Prometheus scrape thẳng bằng tên service
(`backend:8080`, `gateway:8088`, ...) như đã cấu hình sẵn trong `prometheus/
prometheus.yml` — không cần `host.docker.internal` nữa.

## 5. CI/CD — lưu ý trước khi merge

`Jobbeacon-be`, `Jobbeacon-gateway`, `service-discovery`, `jobbeacon-recommendation`,
`Jobbeacon-sync` mỗi repo có `.github/workflows/ci-cd.yml`:

- **Pull request**: chỉ chạy `mvn test`. An toàn.
- **Push vào `main`**: chạy test → build Docker image → push lên GHCR → **SSH vào VM
  production và `docker compose up -d` service đó ngay lập tức.**

Tức là **merge vào `main` = tự động deploy lên production**, không có bước duyệt thủ
công nào khác ở giữa. Nhánh `feat/observability` tôi push cho từng repo (gateway,
discovery, recommendation; `be` dùng nhánh `feat/admin-api` có sẵn) mở PR thoải mái
để xem CI chạy test — chỉ merge khi đã sẵn sàng để nó lên production thật.

Riêng `Jobbeacon-sync`: nhánh `feat/observability` đầu tiên tôi push bị dựng nhầm
trên lịch sử cũ (thiếu 5 commit, trong đó có việc tự thêm CI/CD) — đã xoá, bản đúng
nằm ở `feat/observability-v2`, dựng thẳng từ `main` hiện tại.

`jobbeacon-deployment` không có CI/CD tự động trong repo này — ai đó phải thủ công
`git pull` + `docker compose up -d` lại trên VM. Đổi ở đây (`node-exporter`, mở
Grafana anonymous/embed, thêm `LOKI_URL` cho 4 service) chỉ ảnh hưởng thật khi có
người làm vậy — xác nhận với người giữ VM trước khi merge, đặc biệt là phần Grafana
anonymous (đổi được qua `GRAFANA_ANONYMOUS_ENABLED=false` trong `.env` nếu không
muốn, không cần sửa lại file compose).
