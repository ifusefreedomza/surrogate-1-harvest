# surrogate-1 / quality

### Diagnosis
* The project lacks a robust implementation for handling Hugging Face API rate limits on the discovery side, which can block dataset training.
* The existing implementation may not be reusing existing Lightning Studio instances efficiently, leading to wasted resources and increased costs.
* The project does not have a mechanism to bypass the Hugging Face API rate limit for dataset training, which can cause significant delays.
* The implementation of the surrogate-1 training pipeline may not be optimized for performance, leading to slow training times and inefficient resource utilization.
* The project does not have a comprehensive solution to handle errors and exceptions that may occur during the training process.

### Proposed change
The proposed change is to implement a robust mechanism to handle Hugging Face API rate limits and optimize the surrogate-1 training pipeline for performance. This will involve modifying the `train.py` script to use the Hugging Face CDN to download dataset files, which will bypass the API rate limit. Additionally, we will implement a mechanism to reuse existing Lightning Studio instances and optimize the training pipeline for performance.

### Implementation
To implement the proposed change, we will modify the `train.py` script as follows:
```python
import os
import json
import requests

# Define the Hugging Face CDN URL
cdn_url = "https://huggingface.co/datasets/{repo}/resolve/main/{path}"

# Define the dataset repository and path
repo = "axentx/surrogate-1"
path = "data/train.parquet"

# Download the dataset file from the Hugging Face CDN
response = requests.get(cdn_url.format(repo=repo, path=path), stream=True)
if response.status_code == 200:
    with open("data/train.parquet", "wb") as f:
        for chunk in response.iter_content(1024):
            f.write(chunk)
else:
    print("Failed to download dataset file")

# Load the dataset file
import pandas as pd
df = pd.read_parquet("data/train.parquet")

# Train the model
import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

model = AutoModelForSequenceClassification.from_pretrained("axentx/surrogate-1")
tokenizer = AutoTokenizer.from_pretrained("axentx/surrogate-1")

# Define the training loop
for epoch in range(5):
    model.train()
    for batch in df:
        inputs = tokenizer(batch["text"], return_tensors="pt")
        labels = torch.tensor(batch["label"])
        optimizer = torch.optim.Adam(model.parameters(), lr=1e-5)
        loss = model(**inputs, labels=labels)
        loss.backward()
        optimizer.step()
```
We will also modify the `train.py` script to reuse existing Lightning Studio instances by adding the following code:
```python
import lightning as L

# Define the Lightning Studio instance
studio = L.Studio()

# Check if a studio instance already exists
for s in studio.studios:
    if s.name == "surrogate-1" and s.status == "Running":
        studio = s
        break

# Create a new studio instance if one does not exist
if studio is None:
    studio = L.Studio(create_ok=True)
```
### Verification
To verify that the proposed change works, we can run the `train.py` script and check that the dataset file is downloaded successfully from the Hugging Face CDN. We can also check that the model is trained successfully and that the training loop completes without errors. Additionally, we can check that the Lightning Studio instance is reused correctly by running the `train.py` script multiple times and verifying that the same studio instance is used each time.
