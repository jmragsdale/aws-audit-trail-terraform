import json
import boto3
import hashlib
import os
from datetime import datetime, timezone
from decimal import Decimal

dynamodb = boto3.resource('dynamodb')
s3 = boto3.client('s3')
table = dynamodb.Table(os.environ['AUDIT_TABLE'])

def handler(event, context):
    try:
        if 'body' in event:
            body = json.loads(event['body']) if isinstance(event['body'], str) else event['body']
        else:
            body = event
        
        transaction = {
            'transactionId': body.get('transactionId'),
            'accountId': body.get('accountId'),
            'amount': Decimal(str(body.get('amount', 0))),
            'type': body.get('type'),
            'description': body.get('description', ''),
            'timestamp': datetime.now(timezone.utc).isoformat()
        }
        
        previous_hash = get_latest_hash(transaction['accountId'])
        audit_entry = create_audit_entry(transaction, previous_hash)
        
        table.put_item(Item=audit_entry)
        archive_to_s3(audit_entry)
        
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({
                'message': 'Transaction recorded',
                'auditId': audit_entry['auditId'],
                'hash': audit_entry['hash'],
                'previousHash': previous_hash
            })
        }
    except Exception as e:
        print(f"Error: {e}")
        return {
            'statusCode': 500,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({'error': str(e)})
        }

def create_audit_entry(transaction, previous_hash):
    timestamp = datetime.now(timezone.utc)
    audit_id = f"{transaction['accountId']}-{timestamp.timestamp()}"
    
    hash_input = f"{transaction['transactionId']}{transaction['accountId']}{transaction['amount']}{transaction['type']}{transaction['timestamp']}{previous_hash}"
    current_hash = hashlib.sha256(hash_input.encode()).hexdigest()
    
    return {
        'auditId': audit_id,
        'accountId': transaction['accountId'],
        'transactionId': transaction['transactionId'],
        'amount': transaction['amount'],
        'type': transaction['type'],
        'description': transaction['description'],
        'timestamp': transaction['timestamp'],
        'hash': current_hash,
        'previousHash': previous_hash,
        'ttl': int(timestamp.timestamp()) + (365 * 24 * 60 * 60 * 7)
    }

def get_latest_hash(account_id):
    try:
        response = table.query(
            KeyConditionExpression='accountId = :account_id',
            ExpressionAttributeValues={':account_id': account_id},
            ScanIndexForward=False,
            Limit=1
        )
        return response['Items'][0]['hash'] if response['Items'] else 'GENESIS'
    except Exception as e:
        print(f"Error: {e}")
        return 'GENESIS'

def archive_to_s3(audit_entry):
    try:
        bucket = os.environ['ARCHIVE_BUCKET']
        key = f"audit-logs/{audit_entry['accountId']}/{audit_entry['auditId']}.json"
        
        def decimal_default(obj):
            return float(obj) if isinstance(obj, Decimal) else obj
        
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=json.dumps(audit_entry, indent=2, default=decimal_default),
            ContentType='application/json',
            ServerSideEncryption='AES256'
        )
    except Exception as e:
        print(f"S3 Error: {e}")
