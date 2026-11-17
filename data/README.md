# data

Files mounted read-only into containers. Not committed (see `.gitignore`).

| File | Used by | Where to get it |
|---|---|---|
| `category_embeddings.json` (~50MB) | backend, mounted at `/data/category_embeddings.json` | Google Drive link in `Jobbeacon-be/README.md` |

The backend copies the embeddings into the `category` table on startup, and skips this once every category has one.
Without the file it still starts, but jobs are not classified into categories.
