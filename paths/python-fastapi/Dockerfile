# Vetted golden-path Dockerfile for python-fastapi. Pre-supplied by the
# bootstrap so devops never has to improvise one — the earlier failure mode
# was an LLM-written Dockerfile whose COPY referenced filenames that didn't
# exist on disk. `COPY . .` copies whatever the build agents actually wrote,
# so it can't drift out of sync with the real file layout.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PORT=8081
EXPOSE 8081

CMD ["python", "app.py"]
