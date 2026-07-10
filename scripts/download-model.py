import sys
import os
from huggingface_hub import hf_hub_download

def main():
    if len(sys.argv) < 4:
        print("Usage: python download-model.py <repo_id> <filename> <local_dir>")
        sys.exit(1)
        
    repo_id = sys.argv[1]
    filename = sys.argv[2]
    local_dir = sys.argv[3]
    
    os.makedirs(local_dir, exist_ok=True)
    
    print(f"\nDownloading {filename}")
    print(f"From: {repo_id}")
    print("This may take a while depending on your internet connection...\n")
    
    try:
        path = hf_hub_download(
            repo_id=repo_id, 
            filename=filename, 
            local_dir=local_dir, 
            local_dir_use_symlinks=False
        )
        print(f"\nSuccess! Model saved to: {path}")
    except Exception as e:
        print(f"\nError downloading model: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
