FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir tencentcloud-sdk-python
COPY app.py firewall.py bootstrap.sh /app/
CMD ["python3", "-m", "app"]
