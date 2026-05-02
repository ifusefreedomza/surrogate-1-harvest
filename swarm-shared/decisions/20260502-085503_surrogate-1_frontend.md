# surrogate-1 / frontend

### Diagnosis
* The project lacks a robust frontend implementation for handling Hugging Face API rate limits, which can block dataset training.
* The existing frontend implementation may not be reusing existing Lightning Studio instances efficiently, leading to wasted resources.
* The project does not have a clear implementation for downloading dataset files using the Hugging Face CDN, which can bypass API rate limits.
* The frontend code does not handle Lightning Studio idle timeouts, which can kill training processes.
* The project does not have a mechanism to pre-list file paths and embed them in training scripts, which can reduce API calls during data loading.

### Proposed change
The proposed change is to implement a CDN bypass for the Hugging Face API rate limit and reuse existing Lightning Studio instances to improve efficiency. This will involve modifying the frontend code to download dataset files using the Hugging Face CDN and reusing existing Lightning Studio instances.

### Implementation
To implement the proposed change, we will modify the `train.py` file to download dataset files using the Hugging Face CDN. We will also add a mechanism to pre-list file paths and embed them in the training script.

```python
import json
import requests

# Pre-list file paths and embed them in the training script
def get_file_paths(repo, path):
    url = f"https://huggingface.co/datasets/{repo}/resolve/main/{path}"
    response = requests.get(url)
    file_paths = []
    for file in response.json():
        file_paths.append(file["path"])
    return file_paths

# Download dataset files using the Hugging Face CDN
def download_file(repo, path):
    url = f"https://huggingface.co/datasets/{repo}/resolve/main/{path}"
    response = requests.get(url)
    with open(path, "wb") as f:
        f.write(response.content)

# Reuse existing Lightning Studio instances
def reuse_studio(studio_name):
    for s in Teamspace.studios:
        if s.name == studio_name and s.status == "Running":
            return s
    return None

# Modify the train.py file to use the CDN bypass and reuse existing Lightning Studio instances
def train():
    # Pre-list file paths and embed them in the training script
    file_paths = get_file_paths("repo", "path")
    with open("file_paths.json", "w") as f:
        json.dump(file_paths, f)

    # Download dataset files using the Hugging Face CDN
    for file_path in file_paths:
        download_file("repo", file_path)

    # Reuse existing Lightning Studio instances
    studio = reuse_studio("studio_name")
    if studio:
        # Use the existing studio
        studio.run()
    else:
        # Create a new studio
        studio = Studio(create_ok=True)
        studio.run()

# Handle Lightning Studio idle timeouts
def handle_idle_timeout():
    studio = reuse_studio("studio_name")
    if studio and studio.status == "Stopped":
        # Restart the studio
        studio.start(machine=Machine.L40S)
```

### Verification
To verify that the proposed change works, we can check the following:

* The dataset files are downloaded successfully using the Hugging Face CDN.
* The existing Lightning Studio instances are reused efficiently.
* The training process is not killed by Lightning Studio idle timeouts.
* The API calls during data loading are reduced.

We can verify these by checking the logs, monitoring the training process, and verifying that the dataset files are downloaded successfully.
