### Изначально уже в `values.yaml` прописано то, что Hono тоже надо запускать, но с ним не запускается, поэтому если хочешь запустить OpenTwins без Hono, поменяй в `values.yaml` 

```yaml
hono:
  nameHonoTenant: opentwins
  enabled: false
```
на `False`

```bash
helm install opentwins ./ --wait --timeout=15m --debug
```

