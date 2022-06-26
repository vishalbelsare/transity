import fse from "fs-extra"
import yaml from "js-yaml"
import converter from "converter"

import {
  rmEmptyString,
  keysToEnglish,
  sanitizeYaml,
} from "../helpers.js"


async function normalizeAndPrint (filePathTemp) {
  const csvnorm = await import("csvnorm")
  const csv2json = converter({
    from: "csv",
    to: "json",
    // TODO: Use again when http://github.com/doowb/converter/issues/19 is fixed
    // to: 'yml',
  })

  let jsonTemp = ""
  csv2json.on("data", chunk => {
    jsonTemp += chunk
  })
  csv2json.on("end", () => {
    const transactions = JSON
      .parse(jsonTemp)
      .map(keysToEnglish)
      .reverse() // Now sorted ascending by value date
      .map(transaction => {
        const currency = transaction.currency.replace("EUR", "€")
        const sortedTransaction = Object.assign(
          {
            utc: transaction.utc || transaction["entry-utc"],
            "entry-utc": transaction["entry-utc"],
            note: transaction.note,
          },
          transaction,
        )
        const transfersObj = transaction.amount.startsWith("-")
          ? {
            transfers: [{
              from: "ebase",
              to: noteToAccount(transaction.note),
              amount: transaction.amount.slice(1) + currency,
            }],
          }
          : {
            transfers: [{
              from: noteToAccount(transaction.note),
              to: "ebase",
              // TODO: Remove when github.com/adius/csvnorm/issues/1 is solved
              amount: transaction.amount === "0,00"
                ? 0
                : transaction.amount + currency,
            }],
          }
        const newTransaction = Object.assign(sortedTransaction, transfersObj)

        delete newTransaction.amount
        delete newTransaction.currency
        if (newTransaction["entry-utc"] === newTransaction.utc) {
          delete newTransaction["entry-utc"]
        }
        if (newTransaction["value-utc"] === newTransaction.utc) {
          delete newTransaction["value-utc"]
        }

        return JSON.parse(JSON.stringify(newTransaction, rmEmptyString))
      })

    const yamlString = sanitizeYaml(yaml.dump({transactions}))

    console.info(yamlString)
  })

  csvnorm.default({
    readableStream: fse.createReadStream(filePathTemp),
    writableStream: csv2json,
  })
}

normalizeAndPrint(process.argv[2])
