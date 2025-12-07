# setup pip, venv
sudo apt -y install python3.12-venv python3-pip
python3 -m venv python-env
source python-env/bin/activate

# update pip, download prebuilt pandas (building it is slow on qemu, and probably slow on fpga also)
python3 -m pip install --upgrade pip
pip install pandas --index-url https://gitlab.com/api/v4/projects/56254198/packages/pypi/simple

# download other dependencies (should be faster)
pip install click pyyaml tabulate packaging
