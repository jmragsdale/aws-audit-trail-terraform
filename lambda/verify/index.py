import json
import boto3
import os
from boto3.dynamodb.conditions import Key
from decimal import Decimal

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['AUDIT_TABLE'])

def handler(event, context):
    try:
        account_id = event.get('pathParameters', {}).get('accountId')
        
        if not account_id:
            return {
                'statusCode': 400,
                'headers': {'Content-Type': 'application/json'},
                'body': json.dumps({'error': 'accountId required'})
            }
        
        response = table.query(
            KeyConditionExpression=Key('accountId').eq(account_id),
            ScanIndexForward=True
        )
        
        items = response['Items']
        
        if not items:
            return {
                'statusCode': 404,
                'headers': {'Content-Type': 'application/json'},
                'body': json.dumps({'error': 'No entries found'})
            }
        
        is_valid, broken_at = verify_chain(items)
        
        def decimal_default(obj):
            return float(obj) if isinstance(obj, Decimal) else obj
        
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({
                'accountId': account_id,
                'totalEntries': len(items),
                'chainValid': is_valid,
                'brokenAt': broken_at,
                'firstEntry': items[0]['timestamp'],
                'lastEntry': items[-1]['timestamp']
            }, default=decimal_default)
        }
    except Exception as e:
        print(f"Error: {e}")
        return {
            'statusCode': 500,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({'error': str(e)})
        }

def verify_chain(items):
    for i in range(1, len(items)):
        if items[i]['previousHash'] != items[i-1]['hash']:
            return False, items[i]['auditId']
    return True, None
