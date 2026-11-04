import boto3
import time
import os

def main():
    queue_url = os.environ.get('SQS_QUEUE_URL')
    if not queue_url:
        print("Error: SQS_QUEUE_URL environment variable is missing.")
        return

    sqs = boto3.client('sqs', region_name='us-east-1')
    print(f"Worker iniciado. Escuchando la cola: {queue_url}")

    while True:
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=10  # Long polling
        )

        messages = response.get('Messages', [])
        if not messages:
            print("No hay mensajes. Esperando...")
            continue

        for message in messages:
            body = message['Body']
            print(f"Mensaje recibido: Iniciando procesamiento de {body}")
            
            # Simular tiempo de procesamiento de video (FFmpeg)
            time.sleep(5) 
            
            print(f"Procesamiento de {body} finalizado. Borrando mensaje.")
            sqs.delete_message(
                QueueUrl=queue_url,
                ReceiptHandle=message['ReceiptHandle']
            )

if __name__ == '__main__':
    main()