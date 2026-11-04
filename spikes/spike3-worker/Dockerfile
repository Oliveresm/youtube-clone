FROM python:3.11-slim
RUN pip install boto3
COPY worker.py /app/worker.py
WORKDIR /app
CMD ["python", "-u", "worker.py"]