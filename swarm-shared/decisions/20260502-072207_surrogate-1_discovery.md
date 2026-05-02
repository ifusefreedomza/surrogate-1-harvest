# surrogate-1 / discovery

### Diagnosis
* The project lacks a robust implementation for handling Hugging Face API rate limits on the discovery side, which can block dataset training.
* The existing implementation may not be reusing existing Lightning Studio instances efficiently, leading to wasted resources.
* The project does not have a mechanism to bypass the Hugging Face API rate limit for dataset training, which can be achieved by using the HF CDN.
* The current implementation may be downloading dataset files using the Hugging Face API, which is rate-limited, instead of using the HF CDN.
* The project may not be properly handling errors and retries when encountering rate limits or other issues with the Hugging Face API.

### Proposed change
The proposed change is to implement a mechanism to bypass the Hugging Face API rate limit for dataset training by using the HF CDN. This can be achieved by modifying the `train.py` script to download dataset files from the HF CDN instead of using the Hugging Face API.

### Implementation
To implement this change, we can modify the `train.py` script as follows:
```python
import os
import json
import requests

# Define the Hugging Face dataset repository and file path
repo_id = "your-dataset-repo"
file_path = "your-dataset-file"

# Define the HF CDN URL for the dataset file
cdn_url = f"https://huggingface.co/datasets/{repo_id}/resolve/main/{file_path}"

# Download the dataset file from the HF CDN
response = requests.get(cdn_url)
with open(file_path, "wb") as f:
    f.write(response.content)

# Load the dataset file
dataset = json.load(open(file_path, "r"))

# Train the model using the dataset
# ...
```
We can also add error handling and retries to ensure that the dataset file is downloaded successfully even if the HF CDN is rate-limited.

### Verification
To verify that the change works, we can test the `train.py` script with a sample dataset and check that it downloads the dataset file from the HF CDN successfully. We can also monitor the Hugging Face API rate limit and verify that it is not exceeded during the training process.

Additionally, we can add logging and monitoring to track the performance of the `train.py` script and detect any issues that may arise during the training process.

To reuse existing Lightning Studio instances efficiently, we can modify the `train.py` script to check if a studio instance is already running before creating a new one. We can use the Lightning API to list the running studio instances and check if one with the same name and configuration is already running.
```python
import lightning as L

# Define the studio name and configuration
studio_name = "your-studio-name"
studio_config = {"machine": "L40S", "cloud_compute": "lightning-lambda-prod"}

# List the running studio instances
studios = L.Teamspace.studios()

# Check if a studio instance with the same name and configuration is already running
for studio in studios:
    if studio.name == studio_name and studio.config == studio_config:
        # Reuse the existing studio instance
        print(f"Reusing existing studio instance {studio_name}")
        studio_id = studio.id
        break
else:
    # Create a new studio instance
    print(f"Creating new studio instance {studio_name}")
    studio = L.Studio.create(name=studio_name, config=studio_config)
    studio_id = studio.id
```
We can then use the reused or newly created studio instance to run the training script.
