# How to use

Change directory to `bootstrap`

Iterate over *.age files and decrypt them

    for f in $(find . -name \*.age); do age -d -i ~/.ssh/jabbas ${f} >${f%.*}; done

`bootstrap/secrets.yaml` (PKI klastra Talosa: cluster CA, etcd CA, klucz Service
Accountów) **nie ma odpowiednika `.age`** i nie trafia do gita — playbook generuje
go sam (`talosctl gen secrets`), jeśli pliku nie ma. Istniejący plik nigdy nie jest
nadpisywany, bo odpowiada żywemu klastrowi. Odbudowa od zera bez tego pliku daje
nowe PKI, czyli nowy klaster; SealedSecrety przeżywają, bo ich klucz jest odtwarzany
z `bootstrap/provision/00_sealed_secrets-secret.yaml.age`.

Run the playbook

    ansible-playbook site.yaml

# Encrypt/Decrypt with age

    age -R ~/.ssh/key.pub flux-system-secret.yaml >flux-system-secret.yaml.age
    age -d -i ~/.ssh/key flux-system-secret.yaml.age

# Destroy everything

    rm -f controlplane.yaml talosconfig worker.yaml ~/.talos/config ~/.kube/config && echo 401 402 403 |xargs -n1 ssh pve.home qm stop && echo 401 402 403 |xargs -n1 ssh pve.home qm destroy
