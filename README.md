# jobbeacon-deployment

Docker Compose cho toàn bộ JobBeacon. Cùng một bộ file dùng cho cả máy local lẫn VM.

| File | Nội dung |
|---|---|
| `docker-compose.yml` | Điểm vào, `include` ba file dưới thành một compose project `jobbeacon` |
| `compose.infra.yml` | Postgres, RabbitMQ, Redis, Elasticsearch, Neo4j |
| `compose.apps.yml` | discovery, backend, gateway, crawler, sync, recommendation, frontend |
| `compose.observability.yml` | Loki, Prometheus, Grafana |
| `ci/service-ci-cd.example.yml` | Workflow mẫu, chép sang từng repo service |

Mọi cổng chỉ bind `127.0.0.1`, trừ frontend (cấu hình qua `FRONTEND_BIND`). Backend và recommendation tin header `X-User-*` mà gateway gắn vào, nên tuyệt đối không được mở các cổng này ra ngoài.

## Chạy local

```bash
cp .env.example .env        # điền FIREBASE_PROJECT_ID, VITE_FIREBASE_*, GEMINI_API_KEY
# đặt category_embeddings.json vào data/ (xem data/README.md)
docker compose up -d --build
docker compose up -d postgres elasticsearch rabbitmq redis neo4j discovery   # chỉ hạ tầng, service chạy bằng mvn
```

## CI/CD

```
PR ở repo service
  -> GitHub Actions: chỉ chạy test

push main ở repo service
  -> GitHub Actions: test -> build image -> push ghcr.io/<owner>/<image>:latest
  -> SSH vào VM: docker compose pull <service>
                 docker compose up -d --no-deps --no-build --wait <service>
       chỉ tạo lại container đó; job đỏ nếu container không healthy

push main ở repo này
  -> SSH vào VM: git pull, docker compose up -d (chỉ tạo lại container có cấu hình thay đổi)
                 restart prometheus/loki/grafana/redis nếu file config của chúng đổi
```

VM không build gì cả. `.env` trên VM trỏ mọi `*_IMAGE` tới tag `:latest` trên GHCR. Chỉ giữ một tag nên không có rollback: bản mới lỗi thì sửa code (hoặc `git revert`) rồi push lại.

Secrets, workflow cho từng repo và quyền pull image: xem các bước 4 và 8 ở phần dưới.

## Thiết lập từ đầu tới cuối

Ví dụ dùng VM Ubuntu 22.04/24.04 trên Google Cloud, 16GB RAM. `<owner>` là tên user hoặc organization GitHub, **viết thường**.

### Bước 1. Google Cloud Console

1. **IP tĩnh**: **VPC network** → **IP addresses**, tìm IP ngoài của VM → **Promote to static**. Nếu không làm, IP đổi mỗi lần VM tắt rồi bật, và `VM_HOST` cùng link web sẽ hỏng.
2. **Firewall**: trong trang của VM → **Edit**, tick **Allow HTTP traffic** (thêm **HTTPS** nếu sau này có domain). Cổng 22 đã mở sẵn. Không mở thêm cổng nào khác.
3. **Đĩa**: nên có ít nhất 30–50GB, vì Postgres (gồm cả WAL), Elasticsearch, Neo4j và image Docker đều nằm trên đĩa. Nếu thiếu, tăng ở **Disks** → **Edit**.

### Bước 2. Trên VM: Docker, user `deploy`, swap

SSH vào VM (nút **SSH** trên Console, hoặc `gcloud compute ssh <tên-vm>`):

```bash
# Docker, kèm compose plugin
curl -fsSL https://get.docker.com | sh

# User riêng cho CI, được chạy docker
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy

# Swap 4GB, dự phòng khi RAM tăng đột biến
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Thư mục chứa repo
sudo mkdir -p /opt/jobbeacon && sudo chown deploy:deploy /opt/jobbeacon
```

### Bước 3. SSH key cho GitHub Actions

Chạy trên máy của bạn (không phải VM):

```bash
ssh-keygen -t ed25519 -f jobbeacon-ci -N "" -C "github-actions"
# jobbeacon-ci      private key -> secret VM_SSH_KEY trên GitHub
# jobbeacon-ci.pub  public key  -> authorized_keys của user deploy trên VM
```

Trên VM:

```bash
sudo mkdir -p /home/deploy/.ssh
echo "<nội dung jobbeacon-ci.pub>" | sudo tee -a /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh && sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

Kiểm tra từ máy bạn: `ssh -i jobbeacon-ci deploy@<IP tĩnh> docker ps`. Lệnh in ra bảng container (đang trống) là đúng. Nếu project GCP bật **OS Login**, `authorized_keys` có thể bị bỏ qua. Khi đó tắt OS Login cho VM này (metadata `enable-oslogin=FALSE`), hoặc thêm key qua OS Login.

Đừng commit `jobbeacon-ci`. Sau khi đã dán vào GitHub, xoá nó khỏi máy.

### Bước 4. Secrets trên GitHub

Khai báo trong repo `jobbeacon-deployment` và trong cả 7 repo service (**Settings** → **Secrets and variables** → **Actions** → **New repository secret**). Nếu repo nằm trong organization và để public, khai báo một lần ở organization là đủ.

| Secret | Giá trị |
|---|---|
| `VM_HOST` | IP tĩnh của VM |
| `VM_USER` | `deploy` |
| `VM_SSH_KEY` | toàn bộ nội dung file `jobbeacon-ci`, gồm cả dòng `-----BEGIN/END ...-----` |

### Bước 5. Clone repo này lên VM

Repo public:

```bash
sudo -iu deploy git clone https://github.com/<owner>/jobbeacon-deployment.git /opt/jobbeacon/jobbeacon-deployment
```

Repo private: VM cần quyền đọc, cả lúc clone lẫn lúc CI chạy `git pull`. Dùng **deploy key** chỉ có quyền đọc:

```bash
sudo -iu deploy ssh-keygen -t ed25519 -f /home/deploy/.ssh/github_deploy -N ""
sudo -iu deploy cat /home/deploy/.ssh/github_deploy.pub
# dán vào repo jobbeacon-deployment -> Settings -> Deploy keys -> Add deploy key (không tick write access)
sudo -iu deploy sh -c 'printf "Host github.com\n  IdentityFile ~/.ssh/github_deploy\n" >> ~/.ssh/config'
sudo -iu deploy git clone git@github.com:<owner>/jobbeacon-deployment.git /opt/jobbeacon/jobbeacon-deployment
```

### Bước 6. File `.env`

```bash
sudo -iu deploy
cd /opt/jobbeacon/jobbeacon-deployment
cp .env.example .env
nano .env
```

Sửa các dòng sau (các dòng có đánh dấu `[VM]` trong file):

| Biến | Giá trị trên VM |
|---|---|
| `DISCOVERY_IMAGE` … `FRONTEND_IMAGE` (7 dòng `*_IMAGE`) | `ghcr.io/<owner>/<image>:latest`, tên image theo bảng trong `ci/service-ci-cd.example.yml` |
| `FRONTEND_BIND` / `FRONTEND_PORT` | `0.0.0.0` / `80` |
| `CORS_ORIGINS`, `VITE_API_BASE_URL` | `http://<IP tĩnh>` (hoặc `https://<domain>`) |
| `FIREBASE_PROJECT_ID`, `VITE_FIREBASE_*` | lấy từ Firebase Console → Project settings |
| `GEMINI_API_KEY` | key thật |
| `POSTGRES_PASSWORD`, `RABBITMQ_PASS`, `NEO4J_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` | mật khẩu mạnh, khác giá trị mặc định |
| `ELASTICSEARCH_HEAP` | `1g` |

Phải đặt mật khẩu **trước lần chạy đầu tiên**. Postgres, RabbitMQ và Neo4j chỉ đọc mật khẩu khi khởi tạo volume. Đổi sau đó thì phải đổi cả bên trong từng dịch vụ.

### Bước 7. Firebase

Firebase Console → **Authentication** → **Settings** → **Authorized domains** → thêm IP tĩnh (hoặc domain) của VM. Không có bước này, đăng nhập bị từ chối với lỗi `auth/unauthorized-domain`.

### Bước 8. Tạo image cho cả 7 service

1. Trong mỗi repo service, chép `ci/service-ci-cd.example.yml` sang `.github/workflows/ci-cd.yml`, sửa `SERVICE`, `IMAGE_NAME`, `TEST_COMMAND` theo bảng trong file, rồi push lên `main`.
2. Trong lần đầu, job `deploy` có thể báo đỏ vì hạ tầng trên VM chưa chạy. Không sao, miễn là job `image` xanh.
3. Cho VM được pull image. Chọn một trong hai cách:
   - **Public**: trang repo → **Packages** → package → **Package settings** → **Change visibility** → **Public**. Làm cho cả 7 package.
   - **Private**: tạo PAT (classic) chỉ có quyền `read:packages`, rồi đăng nhập trên VM bằng user `deploy`: `echo <token> | docker login ghcr.io -u <username> --password-stdin`.

### Bước 9. Chạy toàn bộ stack lần đầu

Trên VM, bằng user `deploy`. Trước tiên đặt file embedding của category vào `data/`, bằng cách tải theo link trong `Jobbeacon-be/README.md` hoặc chép từ máy bạn:

```bash
# chạy trên máy bạn
scp category_embeddings.json deploy@<IP tĩnh>:/opt/jobbeacon/jobbeacon-deployment/data/
```

Khi khởi động, BE nạp file này vào bảng `category`. Từ lần sau, thấy mọi category đã có embedding thì BE bỏ qua. Thiếu file thì BE vẫn chạy, nhưng job crawl về sẽ không được phân loại category. Nếu đặt file vào sau khi BE đã chạy, chạy `docker compose restart backend`.

```bash
cd /opt/jobbeacon/jobbeacon-deployment
docker compose up -d --no-build --wait --wait-timeout 900
docker compose ps
```

Nếu còn thiếu dù chỉ một image, `up` sẽ lỗi và không container nào chạy. Khi đó quay lại bước 8.

### Bước 10. Kiểm tra

```bash
curl -I http://localhost/                                         # frontend: 200
curl -s http://localhost:8088/jobbeacon-be/actuator/health         # backend qua gateway: UP
docker stats --no-stream                                          # RAM từng container
```

Mở `http://<IP tĩnh>` trên trình duyệt, đăng nhập thử, xem danh sách job.

Từ giờ, push `main` ở repo nào thì CI tự deploy repo đó.

### Trang nội bộ

Grafana, RabbitMQ, Eureka, Swagger và Neo4j chỉ bind `127.0.0.1`. Xem qua SSH tunnel:

```bash
ssh -i jobbeacon-ci -L 3001:localhost:3001 -L 15672:localhost:15672 -L 8761:localhost:8761 -L 8088:localhost:8088 deploy@<IP tĩnh>
# rồi mở http://localhost:3001 (Grafana), http://localhost:8088/jobbeacon-be/swagger-ui.html ...
```

Docker bỏ qua `ufw`, nên hãy dùng firewall của GCP, đừng dựa vào `ufw` để chặn cổng của container.

## Vận hành

```bash
docker compose ps
docker compose logs -f backend
grep _IMAGE= .env                    # image của từng service
docker compose up -d --no-build      # áp dụng thay đổi trong .env 
```

Đừng chạy `docker compose down -v`, vì lệnh này xoá cả volume dữ liệu. Sync và recommendation mỗi bên giữ một replication slot của Postgres. Nếu tắt chúng lâu, WAL sẽ dồn lại và làm đầy đĩa.
