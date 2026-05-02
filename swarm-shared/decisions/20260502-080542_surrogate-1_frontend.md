# surrogate-1 / frontend

### Diagnosis
* The project lacks a robust implementation for handling Hugging Face API rate limits on the frontend side, which can block dataset training.
* The existing implementation may not be reusing existing Lightning Studio instances efficiently, leading to wasted resources and increased costs.
* The frontend does not have a mechanism to bypass the Hugging Face API rate limit for dataset training, which can cause significant delays.
* The project does not have a clear strategy for handling errors and exceptions related to Hugging Face API rate limits.
* The frontend code does not have a clear and concise way to handle the reuse of existing Lightning Studio instances.

### Proposed change
The proposed change will focus on implementing a mechanism to bypass the Hugging Face API rate limit for dataset training on the frontend side. This will involve modifying the `train.py` file to use the Hugging Face CDN to download dataset files instead of relying on the API.

### Implementation
To implement this change, we will follow these steps:
1. Modify the `train.py` file to use the Hugging Face CDN to download dataset files.
2. Use the `list_repo_tree` method to get the list of files in the dataset repository.
3. Save the list of files to a JSON file.
4. Modify the `train.py` file to read the list of files from the JSON file and download the files from the Hugging Face CDN.

Here is an example of the modified code:
```python
import json
import requests

# Get the list of files in the dataset repository
repo_tree = list_repo_tree(path="path/to/repo", recursive=False)

# Save the list of files to a JSON file
with open("file_list.json", "w") as f:
    json.dump(repo_tree, f)

# Read the list of files from the JSON file
with open("file_list.json", "r") as f:
    file_list = json.load(f)

# Download the files from the Hugging Face CDN
for file in file_list:
    file_url = f"https://huggingface.co/datasets/{repo}/resolve/main/{file}"
    response = requests.get(file_url)
    with open(file, "wb") as f:
        f.write(response.content)
```
We will also modify the `train.py` file to reuse existing Lightning Studio instances. We will use the `Teamspace.studios` method to get the list of existing studios and reuse the running ones.
```python
import lightning

# Get the list of existing studios
studios = Teamspace.studios

# Reuse the running studios
for studio in studios:
    if studio.name == "studio_name" and studio.status == "Running":
        # Reuse the studio
        studio = studio
        break
```
### Verification
To verify that the changes work, we will:
1. Run the `train.py` file and check that the dataset files are downloaded from the Hugging Face CDN.
2. Check that the existing Lightning Studio instances are reused correctly.
3. Monitor the Hugging Face API rate limit and check that it is not exceeded.
4. Verify that the training process completes successfully and that the model is trained correctly.
