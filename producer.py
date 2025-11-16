#!/usr/bin/env python3
"""
Simple REST API Producer for Event Streams
Produces messages to a Kafka topic using Event Streams REST API.

Usage:
    python producer.py --topic TOPIC --rest-api-url URL --username USER --password PASS [--message MSG]

Example:
    python producer.py \\
        --topic Main-Topic-in-Australia \\
        --rest-api-url https://es-demo-ibm-es-recapi-external-tools.apps.6904486b9438192ae56fb793.ap1.techzone.ibm.com \\
        --username pp \\
        --password "q80QKaBR2P0emh1nkUoUZbjBhqXGvVFn" \\
        --message "Geo-Replicated message" \\
        --count 10
"""

import argparse
import sys
import base64
import requests

def produce_message_rest(rest_api_url, topic, username, password, message):
    """Produce a message using Event Streams REST API."""
    url = f"{rest_api_url}/topics/{topic}/records"
    
    # Basic authentication
    credentials = f"{username}:{password}"
    auth_header = base64.b64encode(credentials.encode()).decode()
    
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Basic {auth_header}"
    }
    
    payload = {
        "records": [
            {
                "value": message
            }
        ]
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload, verify=False, timeout=30)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f'❌ REST API error: {e}', file=sys.stderr)
        if hasattr(e, 'response') and e.response is not None:
            print(f'   Status: {e.response.status_code}', file=sys.stderr)
            print(f'   Response: {e.response.text}', file=sys.stderr)
        raise

def main():
    parser = argparse.ArgumentParser(description='REST API Producer for Event Streams')
    parser.add_argument('--topic', required=True, help='Topic name')
    parser.add_argument('--rest-api-url', required=True, help='REST API base URL (e.g., https://es-demo-ibm-es-recapi-external-tools.apps...com)')
    parser.add_argument('--username', required=True, help='SCRAM username')
    parser.add_argument('--password', required=True, help='SCRAM password')
    parser.add_argument('--message', default='Hello from REST API', help='Message content')
    parser.add_argument('--count', type=int, default=1, help='Number of messages (default: 1)')
    
    args = parser.parse_args()
    
    # Remove trailing slash from URL if present
    rest_api_url = args.rest_api_url.rstrip('/')
    
    print(f'🚀 Producing messages via REST API...')
    print(f'   Topic: {args.topic}')
    print(f'   REST API: {rest_api_url}')
    print(f'   Username: {args.username}')
    print('')
    
    # Produce messages
    try:
        for i in range(args.count):
            msg = args.message if args.count == 1 else f"{args.message} ({i+1}/{args.count})"
            
            result = produce_message_rest(rest_api_url, args.topic, args.username, args.password, msg)
            
            if result and 'metadata' in result:
                metadata = result['metadata']
                partition = metadata.get('partition', '?')
                offset = metadata.get('offset', '?')
                print(f'✅ Message {i+1} delivered to {args.topic} [partition {partition}] at offset {offset}')
            elif result and 'offsets' in result and len(result['offsets']) > 0:
                offset_info = result['offsets'][0]
                partition = offset_info.get('partition', '?')
                offset = offset_info.get('offset', '?')
                print(f'✅ Message {i+1} delivered to {args.topic} [partition {partition}] at offset {offset}')
            else:
                print(f'✅ Message {i+1} sent (response: {result})')
        
        print('✅ All messages sent and delivered')
        
    except KeyboardInterrupt:
        print('\n⚠️  Interrupted')
        sys.exit(1)
    except Exception as e:
        print(f'❌ Error: {e}', file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
