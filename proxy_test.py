import requests

def test_proxy():
    proxy_ips = [
        "4.213.32.142",
        "4.213.32.244",
        "4.213.32.248", 
        "4.213.32.160",
        "4.213.32.178",
        "4.213.32.183",
        "4.213.32.165",
        "4.213.32.177",
        "4.213.32.197",
        "4.213.32.174"
    ]
    proxy_port = "3128"
    
    for proxy_ip in proxy_ips:
        proxies = {
            'http': f'http://{proxy_ip}:{proxy_port}',
            'https': f'http://{proxy_ip}:{proxy_port}'
        }
        
        print(f"\nTesting proxy server at {proxy_ip}:{proxy_port}")
        
        try:
            # Test 1: Basic connectivity
            print("\nTest 1: Checking basic connectivity...")
            response = requests.get('http://example.com', proxies=proxies, timeout=10)
            print(f"Status Code: {response.status_code}")
            print(f"Response Headers: {dict(response.headers)}")
            
            # Test 2: Check IP
            print("\nTest 2: Checking IP address...")
            response = requests.get('http://httpbin.org/ip', proxies=proxies, timeout=10)
            print(f"Status Code: {response.status_code}")
            print(f"Response Body: {response.text}")
            if response.status_code == 200:
                print(f"Your IP appears as: {response.json()['origin']}")
                
        except requests.exceptions.RequestException as e:
            print(f"Error: {str(e)}")
            print("\nDebug Information:")
            print(f"Proxy Settings: {proxies}")

if __name__ == "__main__":
    test_proxy()